# frozen_string_literal: true

require "jwt"

# §13 item 7 of docs/architecture/timekeeping-soa.md, against the two running
# applications of the local demo (§11.2):
#
#   Tenant isolation and ownership guards on both tenants; the single-writer
#   guard passes.
#
# Tenant isolation is §6.3's "both seeded businesses ... cannot read, write,
# prepare or project each other's entries". The ownership guards are the
# per-entry rules of §2.1 that decide whose entry a caller may touch inside
# its own business (A2, A5, A6, A7), which §6.2 keeps in the gateway and the
# owner. The single-writer guard is §12.2's, at runtime
# (Timekeeping::SingleWriterWatch): this check counts the violations reported
# in its own process, and bin/timekeeping-demo tenant-isolation reads the
# demo's other processes' logs for any.
#
# It runs under any owner with admission open (legacy, timekeeping or
# monolith), in one step: nothing is stopped or started, and no handoff runs.
# Run it under each owner to see each one hold. Over the public API as each
# seeded business's own users (Timekeeping::PublicApi):
#
#   own         on each business the employee creates entry E, and the admin
#               creates entry M for themselves; the check waits until the
#               projection holds both, so nothing moves it during the checks
#   cross       for each business, against the other's entry E, as its own
#               admin (and employee, for the create):
#               read    the other's employee's entry list answers 404, and so
#                       do the other's client's invoice candidates; the
#                       time-entries report filtered on the other's client
#                       holds none of its entries; and the owner's own read,
#                       in this business, answers not found
#               write   an edit, a discard and a CLI edit of the entry answer
#                       404; a bulk move and a bulk discard of it answer 422,
#                       finding nothing; an entry created on the other's
#                       project answers 404 and is not written. Under the
#                       timekeeping owner the same show, edit and discard are
#                       also sent straight to Timekeeping, under this
#                       business's claims, past the gateway's own lookup:
#                       each answers 404 not-found (§6.3: the owner scopes
#                       every query by the token's company)
#               prepare a draft of this business naming the entry is refused
#                       422 (L8), and no invoice is written
#               project a snapshot delivered to the projection consumer as
#                       the relay delivers one, moving the other's entry, at
#                       its next version, into this business's company and
#                       project, is refused 403 forbidden
#               and the entry is unchanged on its owner and in the
#               projection, and still offered to its own business
#   guards      inside each business: the employee's list of the admin's
#               entries answers the employee's own (A6); the employee's edit
#               and discard of M answer 403 (A5), and a bulk move and a bulk
#               discard of it 422 (A6); the employee's create for the admin
#               answers 403 (A2); the admin's CLI edit of E answers 404, as
#               the CLI edits only the caller's own entries whatever the role
#               (A7). Both entries are unchanged. Then the admin's web edit of
#               E goes through (A5), so the refusals were the guards
#   clean up    each business's E and M are discarded
#
# Last, no single-writer violation was reported in this process while it ran.
# Any check that does not hold raises Failed. A run that finishes leaves, per
# business, two discarded entries and no invoice. One that fails leaves what
# it wrote for inspection.
class Timekeeping::TenantIsolationCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # E, the employee's entry; M, the admin's own.
  DURATIONS = { "E" => 45.0, "M" => 55.0 }.freeze

  SNAPSHOTS = "/internal/v1/projection/entry_snapshots"
  BULK = "/api/v1/timesheet_entry/bulk_action"

  # The relay's service token (entry_snapshot.json service_token_claims).
  RELAY_SUBJECT = "service:timekeeping-relay"
  TOKEN_TTL = 60 # seconds, §6.1

  # The fields of the projection's row a refused call must leave as they were.
  PROJECTED = %w[version note duration project_id user_id bill_status locked discarded_at updated_at].freeze

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # The single-writer guard's violations (Timekeeping::SingleWriterWatch,
  # §11.3) as Rails.error receives them in this process.
  class Violations
    attr_reader :reported

    def initialize
      @reported = []
    end

    def report(error, **)
      @reported << error if error.is_a?(Timekeeping::Signals::Alert) && error.signal == :single_writer
    end
  end

  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
    @cli_tokens = {}
  end

  def call
    @ownership = ensure_open!
    fail! "tenant isolation needs two businesses, and the run names #{@options.tenants.size}" if @options.tenants.size < 2

    violations = Violations.new
    Rails.error.subscribe(violations)
    run_checks
    no_violation!(violations)
    say "neither business could read, write, prepare or project the other's entries, and inside each one an " \
        "employee could not touch the admin's entry, on #{@options.tenants.size} businesses, under owner " \
        "#{@ownership.owner} at generation #{@ownership.generation}; the single-writer guard reported nothing here"
  ensure
    Rails.error.unsubscribe(violations) if violations
  end

  private

    def log_prefix = "tenant isolation"

    def wait = @options.wait

    def ensure_open!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.state_open?

      fail! "the tenant-isolation proof runs while admission is open, under any owner; ownership is #{ownership.summary}"
    end

    def run_checks
      tenants = @options.tenants.map { |tenant| prepare(tenant) }
      tenants.each { |tenant| write_own(tenant) }
      tenants.permutation(2) { |tenant, other| cross_tenant(tenant, other) }
      tenants.each do |tenant|
        ownership_guards(tenant)
        clean_up(tenant)
      end
    end

    def prepare(tenant)
      prepare_tenant(tenant).merge(admin_id: User.find_by!(email: tenant[:admin]).id)
    end

    def note(tenant, letter) = "Tenant isolation #{@run} #{tenant[:company].id} #{letter}"

    def number(tenant, other) = "TIS-#{tenant[:company].id}-#{@run}-#{other[:company].id}"

    # --- own: an entry of the employee's, and one of the admin's ------------

    def write_own(tenant)
      tenant[:own] = { "E" => create_entry(tenant, :employee, "E"), "M" => create_entry(tenant, :admin, "M") }
      ids = tenant[:own].values.map(&:id)
      tenant[:rate] = eventually("the candidates of #{tenant[:name]} offer entries #{ids}") do
        offered = candidates(tenant)
        offered[ids.first] if ids.all? { |id| offered.key?(id) }
      end.fetch("rate")
      ids.each { |id| projected!(tenant, id) }
      say "#{tenant[:name]}: the employee wrote entry #{ids.first} and the admin wrote entry #{ids.last}, and the " \
          "projection holds both"
    end

    # --- cross: one business against the other's entry ---------------------

    def cross_tenant(tenant, other)
      target = other[:own].fetch("E")
      before = isolated_state(other, target)
      reads_refused!(tenant, other, target)
      writes_refused!(tenant, other, target)
      owner_calls_refused!(tenant, target) if @ownership.owner_timekeeping?
      prepare_refused!(tenant, other, target)
      projection_refused!(tenant, other, target)

      after = isolated_state(other, target)
      fail! "#{tenant[:name]}'s calls changed #{other[:name]}'s entry #{target.id}: #{before} became #{after}" unless after == before
      fail! "#{other[:name]}: the candidates no longer offer entry #{target.id}" unless candidates(other).key?(target.id)

      say "#{tenant[:name]}: could not read, write, prepare or project #{other[:name]}'s entry #{target.id}, which is " \
          "unchanged on its owner and in the projection"
    end

    def reads_refused!(tenant, other, target)
      name, other_name, client_id = tenant[:name], other[:name], other[:project].client_id
      query = { from: Date.current.iso8601, to: Date.current.iso8601, user_id: other[:employee_id] }
      status!(as(tenant, :admin).call(:get, "/api/v1/timesheet_entry?#{query.to_query}"), 404,
        "#{name}: the admin's read of #{other_name}'s employee's entry list")
      status!(as(tenant, :admin).call(:get, "/api/v1/invoices/line_items?client_id=#{client_id}"), 404,
        "#{name}: the admin's read of #{other_name}'s invoice candidates")

      shown = report_of(tenant, client_id).keys & other[:own].values.map(&:id)
      fail! "#{name}: the time-entries report filtered on #{other_name}'s client shows its entries #{shown}" if shown.any?

      not_found_in!(tenant, target) { "#{name}: the owner's read of #{other_name}'s entry #{target.id}, in #{name}, found it" }
    end

    def not_found_in!(tenant, target)
      owner_entry(tenant, target.id)
    rescue ActiveRecord::RecordNotFound
      nil
    else
      fail! yield
    end

    def writes_refused!(tenant, other, target)
      id = target.id
      what = "#{tenant[:name]}: the admin's %s of #{other[:name]}'s entry #{id}"
      status!(as(tenant, :admin).call(:patch, "/api/v1/timesheet_entry/#{id}", body: edit_body(tenant, target, "#{target.note} taken")), 404,
        format(what, "edit"))
      status!(as(tenant, :admin).call(:delete, "/api/v1/timesheet_entry/#{id}"), 404, format(what, "discard"))
      status!(cli_call(tenant, :admin, :patch, "/api/v1/cli/timesheet_entries/#{id}", cli_body(tenant, target, "#{target.note} taken")), 404,
        format(what, "CLI edit"))
      status!(as(tenant, :admin).call(:patch, BULK, body: { ids: [id], project_id: tenant[:project].id }), 422, format(what, "bulk move"))
      status!(as(tenant, :admin).call(:delete, BULK, body: { source: { ids: [id] } }), 422, format(what, "bulk discard"))

      planted = "#{note(tenant, 'E')} planted"
      body = { project_id: other[:project].id, timesheet_entry: { duration: 5.0, note: planted, work_date: Date.current.iso8601, bill_status: "unbilled" } }
      status!(as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body:), 404,
        "#{tenant[:name]}: the employee's create on #{other[:name]}'s project #{other[:project].id}")
      planted_ids = [tenant, other].flat_map { |business| entry_list(business, role: :admin).values }.filter_map { |row| row["id"] if row["note"] == planted }
      fail! "#{tenant[:name]}: the refused create on #{other[:name]}'s project wrote entries #{planted_ids}" if planted_ids.any?
    end

    # Under the timekeeping owner: the show, edit and discard sent straight to
    # Timekeeping with this business's claims, past the gateway's lookup.
    def owner_calls_refused!(tenant, target)
      owner_calls(tenant, target).each do |call, send_it|
        answer = begin
          send_it.call
          nil
        rescue Timekeeping::InternalApi::Problem => problem
          problem
        end
        next if answer&.status == 404 && answer.type == "not-found"

        name = tenant[:name]
        fail! "#{name}: Timekeeping answered a #{call} of entry #{target.id} under #{name}'s claims with " \
              "#{answer ? "#{answer.status} #{answer.type}" : 'success'}, not 404 not-found"
      end
    end

    # Each call as the gateway would send it for this business's admin, with
    # the claims (§6.1) and, for a write, the current generation.
    def owner_calls(tenant, target)
      id, project = target.id, tenant[:project]
      admin = User.find(tenant[:admin_id])
      claims = ->(named) { Timekeeping::UserToken.caller_claims(user: admin, company: tenant[:company], writer: "web", project: named, request_id: SecureRandom.uuid) }
      write = -> { Timekeeping::EntryClient::Write.new(claims: claims.call(project), generation: @ownership.generation, idempotency_key: SecureRandom.uuid) }
      client = Timekeeping::EntryClient.new
      {
        "show" => -> { client.show_entry(id, claims: claims.call(nil)) },
        "edit" => -> { client.update_entry(id, { "project_id" => project.id, "note" => "#{target.note} taken" }, write: write.call) },
        "discard" => -> { client.discard_entry(id, write: write.call) }
      }
    end

    # L8: the owner's prepare refuses the other business's entry (and, under
    # the legacy owner, today's line-item validation does).
    def prepare_refused!(tenant, other, target)
      invoice_number = number(tenant, other)
      line = { name: target.note, date: Date.current.iso8601, timesheet_entry_id: target.id, quantity: target.duration, rate: tenant[:rate] }
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number:, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: [line]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      message = response.status == 422 ? response.json["errors"].to_s : nil
      expected = @ownership.owner_legacy? ? "must belong to the same company" : I18n.t("invoices.reservation.refused.wrong_company", entry_id: target.id)
      unless message&.include?(expected)
        fail! "#{tenant[:name]}: a draft naming #{other[:name]}'s entry #{target.id} answered #{response.status} " \
              "#{response.body.to_s.truncate(500)}, not 422 with #{expected.inspect}"
      end

      written = Invoice.with_discarded.where(company: tenant[:company]).where("invoice_number LIKE ?", "%#{invoice_number}").ids
      fail! "#{tenant[:name]}: the refused draft naming #{other[:name]}'s entry left invoices #{written}" if written.any?
    end

    # A delivery to the projection consumer, signed as the relay signs one,
    # that would move the other business's entry, as projected, into this
    # business. Its snapshot keeps the entry snapshot contract, so the
    # refusal is the tenancy one (§6.3), not the contract's.
    def projection_refused!(tenant, other, target)
      row = TimesheetEntry.with_discarded.find(target.id)
      id, name = row.id, tenant[:name]
      before = projected(id)
      response = @client.call(:post, SNAPSHOTS, body: takeover_batch(tenant, row), headers: relay_headers)
      problem = begin
        response.json
      rescue JSON::ParserError
        {}
      end
      unless response.status == 403 && problem["type"] == Timekeeping::Contracts.problem_type("forbidden")
        fail! "#{name}: a snapshot moving #{other[:name]}'s projected entry #{id} into #{name} answered " \
              "#{response.status} #{response.body.to_s.truncate(500)}, not 403 forbidden"
      end

      after = projected(id)
      fail! "#{name}: the refused snapshot changed #{other[:name]}'s projected entry #{id}: #{before} became #{after}" unless after == before
    end

    # One snapshot, at the row's next version, naming this business's company,
    # project and employee.
    def takeover_batch(tenant, row)
      data = Timekeeping::StoredEntries.fields(row)
        .merge("project_id" => tenant[:project].id, "user_id" => tenant[:employee_id], "note" => "#{note(tenant, 'E')} projected")
      snapshot = {
        "type" => Timekeeping::OutboxSnapshot::TYPE, "entry_id" => row.id, "version" => row.version + 1,
        "company_id" => tenant[:company].id, "data" => data
      }
      batch = { "snapshots" => [snapshot] }
      errors = Timekeeping::Contracts.errors(:entry_snapshot, "#/$defs/snapshot_batch", batch)
      fail! "the forged snapshot breaks the entry snapshot contract: #{errors.join('; ')}" if errors.any?

      batch
    end

    # --- guards: whose entry a caller may touch, inside one business --------

    def ownership_guards(tenant)
      entry, admins = tenant[:own].values_at("E", "M")
      ids = [entry.id, admins.id]
      name = tenant[:name]
      before = ids.map { |id| owner_entry(tenant, id) }

      listed = entry_list(tenant, role: :employee, user_id: tenant[:admin_id]).keys
      fail! "#{name}: the employee's list of the admin's entries answered entries #{listed}, not their own (A6)" unless listed.include?(ids.first) && !listed.include?(ids.last)

      employee_refused!(tenant, admins)
      created = create_for_admin!(tenant)
      status!(cli_call(tenant, :admin, :patch, "/api/v1/cli/timesheet_entries/#{ids.first}", cli_body(tenant, entry, "#{entry.note} taken")), 404,
        "#{name}: the admin's CLI edit of the employee's entry #{ids.first} (A7)")

      after = ids.map { |id| owner_entry(tenant, id) }
      fail! "#{name}: the refused calls changed entries #{ids}: #{before} became #{after}" unless after == before

      privileged_edit!(tenant, entry)
      say "#{name}: the employee could neither list, edit, discard, move nor create the admin's entries, and the " \
          "admin's CLI could not edit the employee's (A7); #{created}; the admin's web edit of entry #{ids.first} went through (A5)"
    end

    # A5 for the edit and discard; A6's scope for the bulk move and discard,
    # which find nothing.
    def employee_refused!(tenant, admins)
      id = admins.id
      what = "#{tenant[:name]}: the employee's %s of the admin's entry #{id}"
      employee = as(tenant, :employee)
      status!(employee.call(:patch, "/api/v1/timesheet_entry/#{id}", body: edit_body(tenant, admins, "#{admins.note} taken")), 403, format(what, "edit"))
      status!(employee.call(:delete, "/api/v1/timesheet_entry/#{id}"), 403, format(what, "discard"))
      status!(employee.call(:patch, BULK, body: { ids: [id], project_id: tenant[:project].id }), 422, format(what, "bulk move"))
      status!(employee.call(:delete, BULK, body: { source: { ids: [id] } }), 422, format(what, "bulk discard"))
    end

    def create_for_admin!(tenant)
      planted = "#{note(tenant, 'M')} planted"
      body = entry_body(tenant, duration: 5.0, note: planted).merge(user_id: tenant[:admin_id])
      status!(as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body:), 403, "#{tenant[:name]}: the employee's create for the admin (A2)")
      written = entry_list(tenant, role: :admin, user_id: tenant[:admin_id]).values.filter_map { |row| row["id"] if row["note"] == planted }
      fail! "#{tenant[:name]}: the employee's refused create for the admin wrote entries #{written}" if written.any?

      "the employee's create for the admin was refused (A2)"
    end

    def privileged_edit!(tenant, entry)
      edited = "#{entry.note} edited by the admin"
      response = as(tenant, :admin).call(:patch, "/api/v1/timesheet_entry/#{entry.id}", body: edit_body(tenant, entry, edited))
      expect_ok!(response, "edit the employee's entry #{entry.id} as the admin")
      fail! "#{tenant[:name]}: the admin's edit of entry #{entry.id} did not reach its owner" unless owner_entry(tenant, entry.id)["note"] == edited

      entry.note = edited
    end

    # --- clean up -------------------------------------------------------------

    def clean_up(tenant)
      entry, admins = tenant[:own].values_at("E", "M")
      delete(tenant, :employee, "/api/v1/timesheet_entry/#{entry.id}", "discard entry #{entry.id}")
      delete(tenant, :admin, "/api/v1/timesheet_entry/#{admins.id}", "discard entry #{admins.id}")
      ids = [entry.id, admins.id]
      eventually("entries #{ids} leave the entry lists and the candidates") do
        listed = entry_list(tenant).keys + entry_list(tenant, role: :admin, user_id: tenant[:admin_id]).keys + candidates(tenant).keys
        ids.none? { |id| listed.include?(id) }
      end
      say "#{tenant[:name]}: discarded entries #{ids}"
    end

    # --- writes and calls -----------------------------------------------------

    def create_entry(tenant, role, letter)
      duration = DURATIONS.fetch(letter)
      response = as(tenant, role).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note: note(tenant, letter)))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]} as the #{role}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note: note(tenant, letter))
    end

    def edit_body(tenant, entry, note)
      { project_id: tenant[:project].id, timesheet_entry: { duration: entry.duration, work_date: Date.current.iso8601, note: } }
    end

    def cli_body(tenant, entry, note)
      { timesheet_entry: { project_id: tenant[:project].id, duration_minutes: entry.duration, work_date: Date.current.iso8601, note: } }
    end

    # A CLI session's token, from signing in as the CLI does.
    def cli_token(tenant, role)
      email = tenant.fetch(role)
      @cli_tokens[email] ||= begin
        response = @client.call(:post, "/api/v1/users/login", body: { app: "miru-cli", user: { email:, password: @password } })
        expect_ok!(response, "sign in to the CLI as #{email}")
        response.json.dig("cli_session", "token") || fail!("signing in to the CLI as #{email} answered no token")
      end
    end

    def cli_call(tenant, role, verb, path, body)
      @client.call(verb, path, body:, headers: { "Authorization" => "Bearer #{cli_token(tenant, role)}" })
    end

    # The headers the relay sends: its service token, signed with the shared
    # token key this application verifies it with, and a request id.
    def relay_headers
      key = Rails.configuration.x.timekeeping.token_key.presence || fail!("TIMEKEEPING_TOKEN_KEY is not set, so no delivery can be signed")
      now = Time.current.to_i
      token = JWT.encode({ "sub" => RELAY_SUBJECT, "aud" => "projection", "iat" => now, "exp" => now + TOKEN_TTL }, key, "HS256")
      { "Authorization" => "Bearer #{token}", "X-Request-Id" => "#{@run}-projection-#{SecureRandom.hex(4)}" }
    end

    # --- checks ---------------------------------------------------------------

    def status!(response, expected, what)
      return if response.status == expected

      fail! "#{what} answered #{response.status} #{response.body.to_s.truncate(500)}, not #{expected}"
    end

    def no_violation!(violations)
      return if violations.reported.empty?

      fail! "the single-writer guard reported #{violations.reported.size} violations while the run wrote: " \
            "#{violations.reported.map(&:message).join('; ').truncate(1000)}"
    end

    # --- reads ----------------------------------------------------------------

    # Today's rows of the time-entries report, as the tenant's admin, filtered
    # on `client_id`, by entry id.
    def report_of(tenant, client_id)
      query = { date_range: "custom", from: Date.current.iso8601, to: Date.current.iso8601, client: [client_id] }
      response = as(tenant, :admin).call(:get, "/api/v1/reports/time_entries?#{query.to_query}")
      expect_ok!(response, "read the time-entries report of #{tenant[:name]}")
      response.json.fetch("reports").flat_map { |group| group.fetch("entries") }.index_by { |row| row["id"] }
    end

    # What a business's calls must leave of another's entry: as its owner
    # holds it, and as the projection does.
    def isolated_state(tenant, entry) = { owner: owner_entry(tenant, entry.id), projected: projected(entry.id) }

    def projected(id) = TimesheetEntry.with_discarded.find_by(id:)&.attributes&.slice(*PROJECTED)&.as_json

    # Waits for the relay: until the projection holds the entry at the
    # version its owner holds, so the checks after it compare a projection
    # that no longer moves.
    def projected!(tenant, id)
      eventually("the projection holds entry #{id} at its owner's version") do
        projected(id)&.fetch("version") == owner_entry(tenant, id)["version"]
      end
    end

    # The entry as its owner holds it, read as the entry API's own reads read
    # it under the current owner (Timekeeping::EntryReads), as the tenant's
    # admin, in the tenant's company. Another company's entry is not found.
    def owner_entry(tenant, id)
      admin = User.find(tenant[:admin_id])
      read = Timekeeping::EntryReads::Find.new(id:, company: tenant[:company], writer: "web")
      record = Current.set(user: admin, company: tenant[:company]) { Timekeeping::EntryReads.call(read) }
      { "note" => record.note, "version" => record.version, "locked" => record.locked, "updated_at" => record.updated_at&.utc&.iso8601(6) }
    end
end
