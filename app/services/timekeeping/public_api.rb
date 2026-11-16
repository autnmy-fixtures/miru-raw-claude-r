# frozen_string_literal: true

require "net/http"

# What the local demo's drivers share: the end-to-end journey
# (Timekeeping::Journey, docs/architecture/timekeeping-soa.md §13 item 1),
# the live contract check of the independent-deployment proof
# (Timekeeping::ContractCheck, §13 item 4), the relay-paused proof
# (Timekeeping::RelayPausedCheck, §13 item 5), the user-hard-delete proof
# (Timekeeping::UserDeleteRefusedCheck, §12.4) and the billing-handoff proof
# (Timekeeping::BillingHandoffCheck, §12.4). They drive the existing
# application the way its users do, over its public HTTP API as each seeded
# business's own users (an employee writes entries, an admin or owner writes
# invoices and reads reports), so every write goes through the controllers,
# the write gateway and the invoice reservation boundary to whichever owner
# holds the entries.
#
# A class that includes it sets @client (a Client), @password (the seeded
# users' password), @logger and @sessions ({}), and defines Failed (what a
# check that does not hold raises), log_prefix and wait (how long, in
# seconds, a check that waits on a worker keeps trying).
module Timekeeping::PublicApi
  # The two seeded businesses (db/seeds.rb), and which of their users act.
  TENANTS = [
    { name: "Fork & Leaf Salads", employee: "mateo@forkandleaf.example", admin: "luis@forkandleaf.example" },
    { name: "Copper Kettle Bakery", employee: "lena@copperkettle.example", admin: "hugo@copperkettle.example" }
  ].freeze

  # How long a check that waits on a worker (the relay into the projection,
  # the invoice operation worker's commit) keeps trying, by default.
  DEFAULT_WAIT = 60

  # A JSON client for the existing application's public API. The transport
  # takes a Net::HTTP request and answers [status, content type, body]; the
  # default sends it to base_url, and a spec can hand it to the Rack app.
  class Client
    Response = Data.define(:status, :content_type, :body) do
      def json = JSON.parse(body)
    end

    def initialize(base_url:, transport: nil)
      @base = URI(base_url)
      @transport = transport || method(:over_http)
    end

    def call(verb, path, body: nil, headers: {})
      request = Net::HTTP.const_get(verb.to_s.capitalize).new(URI.join(@base, path))
      { "Accept" => "application/json", "Content-Type" => "application/json", **headers }.each { |key, value| request[key] = value }
      request.body = body.to_json if body
      Response.new(*@transport.call(request))
    end

    private

      def over_http(request)
        response = Net::HTTP.start(@base.host, @base.port, open_timeout: 10, read_timeout: 120) { |http| http.request(request) }
        [response.code.to_i, response["Content-Type"].to_s, response.body.to_s]
      end
  end

  SignedIn = Data.define(:client, :headers) do
    def call(verb, path, body: nil) = client.call(verb, path, body:, headers:)
  end

  private

    def say(message) = @logger.info("#{log_prefix}: #{message}")

    def fail!(message) = raise(self.class::Failed, message)

    # The seeded business named in tenant, its employee, and a billable
    # project of its own the employee is on.
    def prepare_tenant(tenant)
      company = Company.find_by(name: tenant[:name]) || fail!("no seeded business named #{tenant[:name]}")
      employee = User.find_by!(email: tenant[:employee])
      project = employee.project_members.kept.includes(project: :client).map(&:project).find do |candidate|
        candidate.kept? && candidate.billable && candidate.client.kept? && candidate.client.company_id == company.id
      end
      project || fail!("#{tenant[:employee]} is on no billable project of #{tenant[:name]}")

      tenant.merge(company:, employee_id: employee.id, project:, entries: [], drafts: [])
    end

    def entry_body(tenant, duration:, note:)
      {
        project_id: tenant[:project].id,
        timesheet_entry: { duration:, note:, work_date: Date.current.iso8601, bill_status: "unbilled" }
      }
    end

    # The invoice editor's candidate rows for the tenant's client, by entry id.
    def candidates(tenant)
      response = as(tenant, :admin).call(:get, "/api/v1/invoices/line_items?client_id=#{tenant[:project].client_id}")
      expect_ok!(response, "read the invoice candidates")
      response.json.fetch("new_line_item_entries").filter_map do |row|
        [row["timesheet_entry_id"], row] if row["timesheet_entry_id"]
      end.to_h
    end

    # Today's rows of the time-entries report for the tenant's client, by
    # entry id. It reads timesheet_entries, the projection.
    def time_entries_report(tenant)
      query = { date_range: "custom", from: Date.current.iso8601, to: Date.current.iso8601, client: [tenant[:project].client_id] }
      response = as(tenant, :admin).call(:get, "/api/v1/reports/time_entries?#{query.to_query}")
      expect_ok!(response, "read the time-entries report")
      response.json.fetch("reports").flat_map { |group| group.fetch("entries") }.index_by { |row| row["id"] }
    end

    # The employee's entry list (or another user's, as role), which reads
    # through the owner (§3.3). With no entry in the range it answers no
    # `entries` key at all.
    def entry_list(tenant, role: :employee, user_id: tenant[:employee_id])
      query = { from: Date.current.iso8601, to: Date.current.iso8601, user_id: }
      response = as(tenant, role).call(:get, "/api/v1/timesheet_entry?#{query.to_query}")
      expect_ok!(response, "read the entry list")
      response.json.fetch("entries", {}).values.flatten.index_by { |row| row["id"] }
    end

    def same?(entry, row)
      row.present? && row["note"] == entry.note && row["duration"].to_d.round(5) == entry.duration.to_d.round(5)
    end

    def as(tenant, role)
      email = tenant.fetch(role)
      headers = @sessions[email] ||= sign_in(email)
      SignedIn.new(@client, headers)
    end

    def sign_in(email)
      response = @client.call(:post, "/api/v1/users/login", body: { app: "miru-desktop", user: { email:, password: @password } })
      expect_ok!(response, "sign in as #{email}")
      token = response.json.dig("user", "token") || fail!("signing in as #{email} answered no token")
      { "X-Auth-Email" => email, "X-Auth-Token" => token }
    end

    def expect_ok!(response, what)
      return if response.status == 200

      fail! "could not #{what}: #{response.status} #{response.body.to_s.truncate(500)}"
    end

    # A delete answers 200 with a notice, or 204 with nothing.
    def delete(tenant, role, path, what)
      response = as(tenant, role).call(:delete, path)
      expect_ok!(response, what) unless response.status == 204
    end

    def eventually(what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      loop do
        result = yield
        return result if result
        fail! "timed out after #{wait} s waiting until #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.5
      end
    end
end
