# frozen_string_literal: true

require "rails_helper"

# The entry API's own reads through the owner of the entries
# (docs/architecture/timekeeping-soa.md §3.3 rule 1, §5.2 list and show),
# through the real entry points, against the consumer-side fake of
# Timekeeping. Under `timekeeping` the time-tracking list of W1 web and
# mobile (and MCP's miru.time.list) and the lookup before a W1 or W3 update
# or discard, and W2's selection of the entries a bulk move or discard
# names, and W5's duplicate check, read the owner, never the projection,
# which may lag: an entry the relay has not projected yet is listed and
# edited at once (§12.4 "relay paused"), an edit is authorized on the
# owner's current state, and a re-run import skips what the owner holds. The
# public JSON is today's. Under `legacy` nothing changes: no call, today's
# queries.
RSpec.describe "Timekeeping entry reads", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:employee) { tenant_a.employee }
  let(:cli_token) { CliSession.issue_for(user: employee, company: tenant_a.company).last }
  let(:november) { { from: "2026-11-01", to: "2026-11-30" } }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  after { expect(fake.violations).to be_empty }

  def cut_over!
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
  end

  # The projection's row in Timekeeping under the same id, every column as
  # the first cutover copies it (§10.3, §10.4 "Entries: exact").
  def copy_to_owner(entry, **changes)
    fake.seed_entry(
      company_id: entry.project.client.company_id, id: entry.id, **entry.attributes.slice(
        "project_id", "user_id", "agent_id", "duration", "note", "bill_status", "review_status", "locked",
        "source", "source_metadata", "proof_url", "proof_metadata", "external_run_id", "external_session_id"
      ).symbolize_keys, work_date: entry.work_date.iso8601, **changes
    )
  end

  # An entry Timekeeping owns that the relay has not projected yet: no
  # timesheet_entries row holds it (§12.4 "relay paused").
  def unprojected_entry(tenant, user: tenant.employee, work_date: "2026-11-05", **attributes)
    id = TimesheetEntry.maximum(:id).to_i + 1_000 + (@unprojected = @unprojected.to_i + 1)
    fake.seed_entry(
      company_id: tenant.company.id, id:, project_id: tenant.project.id, user_id: user.id,
      duration: 90.7, work_date:, note: "Fresh work", **attributes
    )
  end

  def list(path: api_v1_timesheet_entry_index_path, user: employee, **params)
    send_request :get, path, params: november.merge(params), headers: auth_headers(user)
    expect(response).to have_http_status(:ok)
    json_response.fetch("entries")
  end

  def listed_ids(entries) = entries.values.flatten.pluck("id")

  def calls(operation) = fake.calls.select { |call| call.operation == operation }

  # The member a Harvest file names: Paul Connors, employed by the tenant.
  def import_user(tenant)
    create(:user, first_name: "Paul", last_name: "Connors", current_workspace_id: tenant.company.id).tap do |user|
      create(:employment, company: tenant.company, user:)
    end
  end

  # A Harvest import of `rows` one-hour rows for Paul on the tenant's project,
  # noted "Row 0", "Row 1" and on, all worked on 2026-11-03.
  def harvest_import(tenant, rows:)
    contents = CSV.generate do |csv|
      csv << ["Date", "Client", "Project", "Hours", "First Name", "Last Name", "Notes"]
      rows.times { |index| csv << ["2026-11-03", tenant.client.name, tenant.project.name, 1, "Paul", "Connors", "Row #{index}"] }
    end
    create(:data_import, company: tenant.company, user: tenant.admin, options: {}).tap do |data_import|
      data_import.file.attach(io: StringIO.new(contents), filename: "harvest.csv", content_type: "text/csv")
    end
  end

  def import!(data_import) = Imports::HarvestTimeEntriesImporter.new(data_import).process

  describe "under the timekeeping owner" do
    describe "W1 time-tracking list" do
      before { sign_in employee }

      it "lists the owner's entries exactly as today's list of the same entries" do
        entries = [
          unbilled_entry(tenant_a, work_date: "2026-11-02", duration: 90.7, note: "Older"),
          unbilled_entry(tenant_a, work_date: "2026-11-04", duration: 30, note: "Newer", source: "cli"),
          unbilled_entry(tenant_a, work_date: "2026-11-03", duration: 45, note: "Non-billable", bill_status: :non_billable)
        ]
        today = list
        entries.each { |entry| copy_to_owner(entry) }

        cut_over!
        expect(list).to eq(today)
        expect(today.keys).to eq(%w[2026-11-04 2026-11-03 2026-11-02])
      end

      it "lists an entry the projection does not hold yet, from the owner's current state" do
        projected = unbilled_entry(tenant_a, work_date: "2026-11-02", note: "Before")
        copy_to_owner(projected, note: "After")
        fresh = unprojected_entry(tenant_a)
        cut_over!

        entries = without_projection_reads { list }

        expect(TimesheetEntry.where(id: fresh["id"])).to be_empty
        expect(listed_ids(entries)).to eq([fresh["id"], projected.id])
        expect(entries.fetch("2026-11-05").sole).to include(
          "id" => fresh["id"], "duration" => 90.7, "note" => "Fresh work", "type" => "timesheet",
          "project" => tenant_a.project.name, "project_id" => tenant_a.project.id, "client" => tenant_a.client.name,
          "team_member" => employee.full_name, "bill_status" => "unbilled"
        )
        expect(entries.fetch("2026-11-02").sole["note"]).to eq("After")
        call = calls(:list_entries).sole
        expect(call.input).to eq("user_id" => employee.id.to_s, "from" => "2026-11-01", "to" => "2026-11-30")
        expect(call.claims).to include(
          "sub" => "user:#{employee.id}", "company_id" => tenant_a.company.id, "role" => "employee", "writer" => "web"
        )
      end

      it "lists every page the owner answers" do
        fake = TimekeepingContracts::FakeTimekeeping.new(generation: 1, list_page_size: 2).install!
        ids = Array.new(5) { |day| fake.seed_entry(
          company_id: tenant_a.company.id, project_id: tenant_a.project.id, user_id: employee.id,
          duration: 30.0, work_date: "2026-11-1#{day}"
        )["id"] }
        cut_over!

        expect(listed_ids(list)).to eq(ids.reverse)
        expect(fake.calls.map { |call| call.input["cursor"] }).to eq([nil, "2", "4"])
        expect(fake.violations).to be_empty
      end

      it "lists the selected member for an admin, as today (A6)" do
        admin = tenant_a.admin
        sign_in admin
        fresh = unprojected_entry(tenant_a)
        cut_over!

        expect(listed_ids(list(user: admin, user_id: employee.id))).to eq([fresh["id"]])
        expect(calls(:list_entries).sole.input).to include("user_id" => employee.id.to_s)
        expect(calls(:list_entries).sole.claims).to include("sub" => "user:#{admin.id}", "role" => "admin")
      end

      it "reads as the mobile writer on the mobile route, and as the MCP writer for miru.time.list" do
        fresh = unprojected_entry(tenant_a)
        cut_over!

        expect(listed_ids(list(path: "/api/v1/mobile/timesheet_entries"))).to eq([fresh["id"]])
        result = MCP::Miru::Tools::TimeListTool.call(**november, server_context: { authorization: cli_token })

        expect(result.error?).to be(false)
        expect(listed_ids(JSON.parse(result.content.sole[:text]).dig("data", "entries"))).to eq([fresh["id"]])
        expect(calls(:list_entries).map { |call| call.claims.fetch("writer") }).to eq(%w[mobile mcp])
      end

      it "never lists tenant B's entries (§6.3)" do
        unprojected_entry(tenant_b, user: tenant_b.employee)
        mine = unprojected_entry(tenant_a)
        cut_over!

        expect(listed_ids(list)).to eq([mine["id"]])
        expect(calls(:list_entries).sole.claims.fetch("company_id")).to eq(tenant_a.company.id)
      end

      it "answers a retryable 503 when Timekeeping cannot be reached" do
        cut_over!
        WebMock::API.stub_request(:get, %r{/internal/v1/entries}).to_raise(Faraday::ConnectionFailed.new("refused"))

        send_request :get, api_v1_timesheet_entry_index_path, params: november, headers: auth_headers(employee)

        expect(response).to have_http_status(:service_unavailable)
        expect(json_response["errors"]).to eq(I18n.t("timesheet_entry.unavailable"))
      end
    end

    describe "W1 update and discard" do
      before do
        sign_in employee
        cut_over!
      end

      it "edits and discards an entry the projection does not hold yet" do
        fresh = unprojected_entry(tenant_a, work_date: Date.current.iso8601)

        writes = timesheet_entry_writes do
          send_request :patch, api_v1_timesheet_entry_path(fresh["id"]), params: {
            project_id: tenant_a.project.id, timesheet_entry: { duration: 60, work_date: Date.current.iso8601, note: "Edited" }
          }, headers: auth_headers(employee)
          expect(response).to have_http_status(:ok)
          expect(json_response.dig("entry", "note")).to eq("Edited")

          send_request :delete, api_v1_timesheet_entry_path(fresh["id"]), headers: auth_headers(employee)
          expect(response).to have_http_status(:ok)
        end

        expect(writes).to eq([])
        expect(fake.entry(fresh["id"])).to include("note" => "Edited", "discarded_at" => be_present)
        expect(fake.calls.map(&:operation)).to eq(%i[show_entry update_entry show_entry discard_entry])
        expect(calls(:show_entry).map { |call| call.claims.fetch("writer") }).to eq(%w[web web])
      end

      it "authorizes on the owner's state, not the projection's: an entry billed in Timekeeping is refused (A3)" do
        entry = unbilled_entry(tenant_a, work_date: Date.current)
        copy_to_owner(entry, bill_status: "billed")

        send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(employee)

        expect(response).to have_http_status(:forbidden)
        expect(fake.calls.map(&:operation)).to eq(%i[show_entry])
        expect(fake.entry(entry.id)["discarded_at"]).to be_nil
      end

      it "answers today's not-found for an entry the owner does not hold, tenant B's included (§6.3)" do
        foreign = unprojected_entry(tenant_b, user: tenant_b.employee)
        discarded = unprojected_entry(tenant_a, discarded_at: "2026-11-06T10:00:00.000000Z")

        [foreign, discarded].each do |entry|
          send_request :delete, api_v1_timesheet_entry_path(entry["id"]), headers: auth_headers(employee)
          expect(response).to have_http_status(:not_found)
        end
        send_request :delete, api_v1_timesheet_entry_path("not-an-id"), headers: auth_headers(employee)
        expect(response).to have_http_status(:not_found)

        expect(fake.calls.map(&:operation)).to eq(%i[show_entry show_entry])
        expect(fake.entry(foreign["id"])["discarded_at"]).to be_nil
      end
    end

    describe "W3 CLI and W3a MCP update and discard" do
      before { cut_over! }

      it "edits and discards the caller's own entry the projection does not hold yet" do
        fresh = unprojected_entry(tenant_a, work_date: Date.current.iso8601)

        send_request :patch, api_v1_cli_timesheet_entry_path(fresh["id"]), params: { timesheet_entry: {
          project_id: tenant_a.project.id, duration_minutes: 45, work_date: Date.current.iso8601, note: "edited"
        } }, headers: cli_auth_headers(cli_token)
        expect(response).to have_http_status(:ok)
        result = MCP::Miru::Tools::TimeDeleteTool.call(id: fresh["id"], server_context: { authorization: cli_token })

        expect(result.error?).to be(false)
        expect(fake.entry(fresh["id"])).to include("note" => "edited", "discarded_at" => be_present)
        expect(calls(:show_entry).map { |call| call.claims.fetch("writer") }).to eq(%w[cli mcp])
      end

      it "answers not-found for another member's entry, whatever the caller's role (A7)" do
        admin_token = CliSession.issue_for(user: tenant_a.admin, company: tenant_a.company).last
        theirs = unprojected_entry(tenant_a, user: employee)

        send_request :delete, api_v1_cli_timesheet_entry_path(theirs["id"]), headers: cli_auth_headers(admin_token)

        expect(response).to have_http_status(:not_found)
        expect(fake.calls.map(&:operation)).to eq(%i[show_entry])
        expect(fake.entry(theirs["id"])["discarded_at"]).to be_nil
      end
    end

    describe "W2 bulk move and bulk discard" do
      let(:other_project) do
        create(:project, client: tenant_a.client, billable: true).tap do |project|
          create(:project_member, project:, user: employee)
        end
      end

      before do
        sign_in employee
        cut_over!
      end

      def bulk_move(ids, user: employee)
        send_request :patch, api_v1_bulk_action_path, params: { ids:, project_id: other_project.id }, headers: auth_headers(user)
      end

      def bulk_discard(ids, user: employee)
        send_request :delete, api_v1_bulk_action_path, params: { source: { ids: } }, headers: auth_headers(user)
      end

      it "moves and discards entries the projection does not hold yet, selected from the owner" do
        first, second = 2.times.map { unprojected_entry(tenant_a, work_date: Date.current.iso8601) }

        writes = timesheet_entry_writes do
          without_projection_reads { bulk_move([first["id"], second["id"]]) }
          expect(response).to have_http_status(:ok)
          expect(json_response["entries"].values.flatten.map { |entry| [entry["id"], entry["project_id"]] })
            .to contain_exactly([first["id"], other_project.id], [second["id"], other_project.id])

          without_projection_reads { bulk_discard([first["id"]]) }
          expect(response).to have_http_status(:ok)
          expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
        end

        expect(writes).to eq([])
        expect(fake.entry(first["id"])).to include("project_id" => other_project.id, "discarded_at" => be_present)
        expect(fake.entry(second["id"])).to include("project_id" => other_project.id, "discarded_at" => nil)
        expect(fake.calls.map(&:operation)).to eq(%i[list_entries bulk_move list_entries bulk_discard])
        expect(calls(:list_entries).map(&:input)).to eq([
          { "ids" => [first["id"], second["id"]].map(&:to_s), "user_id" => employee.id.to_s },
          { "ids" => [first["id"].to_s], "user_id" => employee.id.to_s }
        ])
        expect(calls(:list_entries).map(&:claims)).to all(include(
          "sub" => "user:#{employee.id}", "company_id" => tenant_a.company.id, "role" => "employee", "writer" => "bulk"
        ))
      end

      it "judges A9's lock on the owner's state: an entry billed in Timekeeping is refused" do
        entry = unbilled_entry(tenant_a, work_date: Date.current)
        copy_to_owner(entry, bill_status: "billed")
        days = tenant_a.company.timesheet_edit_days

        bulk_move([entry.id])
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.update.locked", days:))
        bulk_discard([entry.id])
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.destroy.locked", days:))

        expect(fake.calls.map(&:operation)).to eq(%i[list_entries list_entries])
        expect(fake.entry(entry.id)).to include("project_id" => tenant_a.project.id, "discarded_at" => nil)
      end

      it "selects an employee's own entries only, and any member's for an admin (A6)" do
        admin = tenant_a.admin
        mine = unprojected_entry(tenant_a, work_date: Date.current.iso8601)
        theirs = unprojected_entry(tenant_a, user: admin, work_date: Date.current.iso8601)

        bulk_discard([theirs["id"]])
        expect(response).to have_http_status(:unprocessable_entity)
        expect(fake.calls.map(&:operation)).to eq(%i[list_entries])
        expect(fake.entry(theirs["id"])["discarded_at"]).to be_nil

        sign_in admin
        bulk_discard([mine["id"], theirs["id"]], user: admin)
        expect(response).to have_http_status(:ok)
        expect([mine, theirs].map { |entry| fake.entry(entry["id"])["discarded_at"] }).to all(be_present)
        expect(calls(:list_entries).last.input).to eq("ids" => [mine["id"], theirs["id"]].map(&:to_s))
        expect(calls(:list_entries).last.claims).to include("sub" => "user:#{admin.id}", "role" => "admin")
      end

      it "never selects tenant B's entries (§6.3)" do
        foreign = unprojected_entry(tenant_b, user: tenant_b.employee, work_date: Date.current.iso8601)

        bulk_move([foreign["id"]])

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.update.failure", default: "No entries found"))
        expect(fake.calls.map(&:operation)).to eq(%i[list_entries])
        expect(calls(:list_entries).sole.claims.fetch("company_id")).to eq(tenant_a.company.id)
        expect(fake.entry(foreign["id"])).to include("project_id" => tenant_b.project.id, "discarded_at" => nil)
      end

      it "answers a retryable 503 when Timekeeping cannot be reached" do
        WebMock::API.stub_request(:get, %r{/internal/v1/entries}).to_raise(Faraday::ConnectionFailed.new("refused"))

        bulk_discard([unprojected_entry(tenant_a)["id"]])

        expect(response).to have_http_status(:service_unavailable)
        expect(json_response["errors"]).to eq(I18n.t("timesheet_entry.unavailable"))
      end
    end
    describe "W5 Harvest import's duplicate check" do
      let(:paul) { import_user(tenant_a) }

      # An entry an earlier import wrote, which the owner holds and the relay
      # has not projected yet.
      def imported_entry(tenant, note:, user: paul, project_id: tenant.project.id, **attributes)
        unprojected_entry(
          tenant, user:, project_id:, work_date: "2026-11-03", duration: 60.0, note:, source: "import", **attributes
        )
      end

      it "skips the rows the owner already holds, though the projection does not hold them yet" do
        held = imported_entry(tenant_a, note: "Row 0")
        imported_entry(tenant_a, note: "Row 1", source: "manual")
        imported_entry(tenant_a, note: "Row 2", discarded_at: "2026-11-04T10:00:00.000000Z")
        imported_entry(tenant_b, user: tenant_b.employee, project_id: tenant_a.project.id, note: "Row 3")
        data_import = harvest_import(tenant_a, rows: 4)
        cut_over!

        writes = timesheet_entry_writes { without_projection_reads { import!(data_import) } }

        expect(writes).to eq([])
        expect(TimesheetEntry.where(id: held["id"])).to be_empty
        expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 3, skipped_rows: 1)
        expect(data_import.summary["duplicates_skipped"]).to eq(1)
        expect(fake.calls.map(&:operation)).to eq(%i[list_entries import_batch])
        expect(calls(:import_batch).sole.input.fetch("rows").pluck("note")).to eq(["Row 1", "Row 2", "Row 3"])
        read = calls(:list_entries).sole
        expect(read.input).to eq("project_ids" => [tenant_a.project.id.to_s], "from" => "2026-11-03", "to" => "2026-11-03")
        expect(read.claims).to include("sub" => "system", "company_id" => tenant_a.company.id, "writer" => "import")
      end

      it "asks nothing of the owner for a discarded project, whose entries are no duplicates, as today" do
        imported_entry(tenant_a, note: "Row 0")
        tenant_a.project.discard!
        data_import = harvest_import(tenant_a, rows: 1)
        cut_over!

        import!(data_import)

        expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 1, skipped_rows: 0)
        expect(fake.calls.map(&:operation)).to eq(%i[import_batch])
      end

      it "fails the import and writes nothing when Timekeeping cannot be reached" do
        data_import = harvest_import(tenant_a, rows: 1)
        cut_over!
        WebMock::API.stub_request(:get, %r{/internal/v1/entries}).to_raise(Faraday::ConnectionFailed.new("refused"))

        expect { import!(data_import) }.to raise_error(Timekeeping::EntryClient::Unavailable)
        expect(data_import.reload).to have_attributes(status: "failed", error_message: I18n.t("imports.errors.unexpected"))
        expect(calls(:import_batch)).to be_empty
      end
    end
  end

  it "reads the table under the legacy owner for W5's duplicate check, as today" do
    import_user(tenant_a)
    import!(harvest_import(tenant_a, rows: 2))
    again = harvest_import(tenant_a, rows: 2)

    import!(again)

    expect(again.reload).to have_attributes(status: "completed", imported_rows: 0, skipped_rows: 2)
    expect(fake.calls).to be_empty
  end

  it "makes no call under the legacy owner, which still reads the table" do
    sign_in employee
    entry = unbilled_entry(tenant_a, work_date: "2026-11-02")

    expect(listed_ids(list)).to eq([entry.id])
    send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(employee)
    expect(response).to have_http_status(:ok)
    bulk = unbilled_entry(tenant_a, work_date: Date.current)
    send_request :delete, api_v1_bulk_action_path, params: { source: { ids: [bulk.id] } }, headers: auth_headers(employee)
    expect(response).to have_http_status(:ok)

    expect([entry.reload, bulk.reload]).to all(be_discarded)
    expect(fake.calls).to be_empty
  end

  # Runs the reader and asserts no timesheet_entries query was made: what
  # was listed came from the owner. The time-off and holiday reads beside it
  # are not entries.
  def without_projection_reads(&reader)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?(%("timesheet_entries")) }
    result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &reader)
    expect(queries).to eq([]), "the list read the projection"
    result
  end
end
