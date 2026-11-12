# frozen_string_literal: true

require "rails_helper"

# Entry writes forwarded to Timekeeping (docs/architecture/timekeeping-soa.md
# §3.1, §5.2, §6.1), through the real entry points of W1 web and mobile, W2
# bulk, W3 CLI, W3a MCP, W4 agent, W5 Harvest import and W6 agent destroy,
# against the consumer-side fake of Timekeeping.
# Under `timekeeping` each write reaches the owner with its writer's claims,
# answers today's public JSON from the owner's entry, and writes nothing to
# timesheet_entries, which is the projection with one writer (§3.2, §12.2).
# Tenant B's entries are never touched (§6.3).
RSpec.describe "Timekeeping entry forwarding", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:employee) { tenant_a.employee }
  let(:cli_token) { CliSession.issue_for(user: employee, company: tenant_a.company).last }

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

  # An entry in the projection and in Timekeeping under the same id, as the
  # first cutover leaves it (§10.3).
  def owned_entry(tenant, **attributes)
    unbilled_entry(tenant, **attributes).tap do |entry|
      fake.seed_entry(
        company_id: tenant.company.id, id: entry.id, project_id: entry.project_id, user_id: entry.user_id,
        duration: entry.duration, work_date: entry.work_date.iso8601, note: entry.note
      )
    end
  end

  # Runs the writer and asserts the projection was not written.
  def without_projection_writes(&writer)
    writes = timesheet_entry_writes(&writer)
    expect(writes).to eq([]), "a forwarded write wrote timesheet_entries"
  end

  def entry_params(**overrides)
    { duration: 90.7, work_date: "2026-11-02", note: "Forwarded", bill_status: "unbilled", **overrides }
  end

  def cli_params(**overrides)
    { timesheet_entry: { project_id: tenant_a.project.id, duration_minutes: 30, work_date: "2026-11-02", **overrides } }
  end

  # The writes that reached the owner; an update or discard first reads the
  # entry from it, and a bulk move or discard the entries it names (§3.3
  # rule 1, spec/requests/timekeeping/entry_reads_spec.rb).
  def writes = fake.calls.reject { |call| %i[show_entry list_entries].include?(call.operation) }

  def writers = writes.map { |call| call.claims.fetch("writer") }

  # Today's JSON for the owner's entry: the snippet the controllers render.
  def expect_rendered(entry_json, owned)
    expect(entry_json).to include(
      "id" => owned["id"], "project_id" => owned["project_id"], "project" => tenant_a.project.name,
      "client" => tenant_a.client.name, "duration" => owned["duration"], "note" => owned["note"],
      "work_date" => owned["work_date"], "bill_status" => owned["bill_status"], "team_member" => employee.full_name,
      "type" => "timesheet"
    )
  end

  describe "under the timekeeping owner" do
    before { cut_over! }

    describe "W1 web" do
      before { sign_in employee }

      it "creates in Timekeeping, renders the owner's entry as today, and leaves the projection to the relay" do
        without_projection_writes do
          send_request :post, api_v1_timesheet_entry_index_path,
            params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(employee)
        end

        expect(response).to have_http_status(:ok)
        expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.create.message"))
        owned = fake.entry(json_response.dig("entry", "id"))
        expect(owned).to include("company_id" => tenant_a.company.id, "user_id" => employee.id, "duration" => 90.7, "note" => "Forwarded")
        expect_rendered(json_response["entry"], owned)
        expect(TimesheetEntry.where(id: owned["id"])).to be_empty
        expect(fake.calls.sole.claims).to include(
          "sub" => "user:#{employee.id}", "company_id" => tenant_a.company.id, "role" => "employee", "writer" => "web",
          "project" => include("id" => tenant_a.project.id, "company_id" => tenant_a.company.id)
        )
      end

      it "updates and discards through the owner" do
        entry = owned_entry(tenant_a, note: "Before")

        without_projection_writes do
          send_request :patch, api_v1_timesheet_entry_path(entry.id),
            params: { project_id: tenant_a.project.id, timesheet_entry: entry_params(note: "After") }, headers: auth_headers(employee)
          expect(response).to have_http_status(:ok)
          expect_rendered(json_response["entry"], fake.entry(entry.id))
          expect(json_response.dig("entry", "note")).to eq("After")

          send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(employee)
          expect(response).to have_http_status(:ok)
        end

        expect(fake.entry(entry.id)).to include("note" => "After", "discarded_at" => be_present, "version" => 3)
        expect(entry.reload).to have_attributes(note: "Before", discarded_at: nil)
        expect(writers).to eq(%w[web web])
      end

      it "answers what the owner refuses as today's error JSON" do
        fake.fail_next(:create_entry, status: 422, slug: "validation-failed", retryable: false,
          errors: { "work_date" => ["can't be blank"] })

        send_request :post, api_v1_timesheet_entry_index_path,
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(employee)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response["errors"]).to eq("Work date can't be blank")
      end

      it "answers a retryable 503 when Timekeeping cannot be reached" do
        WebMock::API.stub_request(:post, %r{/internal/v1/entries\z}).to_raise(Faraday::ConnectionFailed.new("refused"))
        allow(Timekeeping::EntryClient).to receive(:new).and_wrap_original { |original| original.call(backoff: ->(_) { }) }

        send_request :post, api_v1_timesheet_entry_index_path,
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(employee)

        expect(response).to have_http_status(:service_unavailable)
        expect(json_response["errors"]).to eq(I18n.t("timesheet_entry.unavailable"))
      end

      it "never reaches tenant B's entry (§6.3)" do
        foreign = owned_entry(tenant_b)

        send_request :delete, api_v1_timesheet_entry_path(foreign.id), headers: auth_headers(employee)

        expect(response).to have_http_status(:not_found)
        expect(writes).to be_empty
        expect(fake.entry(foreign.id)["discarded_at"]).to be_nil
      end
    end

    it "W1 mobile creates as the mobile writer" do
      sign_in employee

      without_projection_writes do
        post "/api/v1/mobile/timesheet_entries",
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(employee)
      end

      expect(response).to have_http_status(:ok)
      expect_rendered(json_response["entry"], fake.entry(json_response.dig("entry", "id")))
      expect(writers).to eq(%w[mobile])
    end

    it "W3 CLI creates, updates and discards as the CLI writer" do
      entry = owned_entry(tenant_a)

      without_projection_writes do
        send_request :post, api_v1_cli_timesheet_entries_path, params: cli_params, headers: cli_auth_headers(cli_token)
        expect(response).to have_http_status(:ok)
        expect(json_response["entry"]).to include("source" => "cli", "duration" => 30.0)

        send_request :patch, api_v1_cli_timesheet_entry_path(entry.id), params: cli_params(note: "edited"), headers: cli_auth_headers(cli_token)
        expect(response).to have_http_status(:ok)
        expect(json_response.dig("entry", "note")).to eq("edited")

        send_request :delete, api_v1_cli_timesheet_entry_path(entry.id), headers: cli_auth_headers(cli_token)
        expect(response).to have_http_status(:ok)
      end

      expect(writers).to eq(%w[cli cli cli])
    end

    it "W3a MCP creates in-process through W3, as the MCP writer" do
      result = nil
      without_projection_writes do
        result = MCP::Miru::Tools::TimeCreateTool.call(
          project_id: tenant_a.project.id, duration_minutes: 30, work_date: "2026-11-02",
          server_context: { authorization: cli_token }
        )
      end

      expect(result.error?).to be(false)
      expect(writers).to eq(%w[mcp])
      expect(fake.calls.sole.claims).to include("sub" => "user:#{employee.id}", "actor" => { "type" => "user", "agent_id" => nil })
    end

    it "W4 agent creates as the agent, which Timekeeping sets on the entry" do
      agent = create(:agent, company: tenant_a.company, user: employee, default_project: tenant_a.project)
      agent_token = AgentKey.issue_for(agent:, name: "Forwarding", created_by: tenant_a.admin).last

      without_projection_writes do
        send_request :post, api_v1_agent_timesheet_entries_path,
          params: { timesheet_entry: { duration_minutes: 30, work_date: "2026-11-02", note: "Agent run" } },
          headers: { "Authorization" => "Bearer #{agent_token}" }
      end

      expect(response).to have_http_status(:ok)
      expect(json_response["entry"]).to include("agent_id" => agent.id, "agent_name" => agent.name, "source" => "automation")
      expect(fake.entry(json_response.dig("entry", "id"))).to include("agent_id" => agent.id, "user_id" => employee.id)
      expect(fake.calls.sole.claims).to include("writer" => "agent", "actor" => { "type" => "agent", "agent_id" => agent.id })
    end

    describe "W2 bulk" do
      let!(:first) { owned_entry(tenant_a, note: "First") }
      let!(:second) { owned_entry(tenant_a, note: "Second") }
      let(:other_project) do
        create(:project, client: tenant_a.client, billable: true).tap do |project|
          create(:project_member, project:, user: employee)
        end
      end

      before { sign_in employee }

      def bulk_move(*entries)
        send_request :patch, api_v1_bulk_action_path,
          params: { ids: entries.map(&:id), project_id: other_project.id }, headers: auth_headers(employee)
      end

      def bulk_discard(*entries)
        send_request :delete, api_v1_bulk_action_path, params: { source: { ids: entries.map(&:id) } }, headers: auth_headers(employee)
      end

      it "moves through the owner and renders the owner's entries as today" do
        without_projection_writes { bulk_move(first, second) }

        expect(response).to have_http_status(:ok)
        expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.update.message"))
        rendered = json_response["entries"].values.flatten
        expect(rendered.map { |entry| [entry["id"], entry["project_id"], entry["project"]] })
          .to contain_exactly([first.id, other_project.id, other_project.name], [second.id, other_project.id, other_project.name])
        expect([first, second].map { |entry| fake.entry(entry.id)["project_id"] }).to all(eq(other_project.id))
        expect([first, second].map { |entry| entry.reload.project_id }).to all(eq(tenant_a.project.id))
        expect(writes.sole.claims).to include(
          "sub" => "user:#{employee.id}", "role" => "employee", "writer" => "bulk",
          "project" => include("id" => other_project.id)
        )
      end

      it "discards through the owner" do
        without_projection_writes { bulk_discard(first) }

        expect(response).to have_http_status(:ok)
        expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
        expect(fake.entry(first.id)["discarded_at"]).to be_present
        expect(fake.entry(second.id)["discarded_at"]).to be_nil
        expect(first.reload).not_to be_discarded
        expect(writers).to eq(%w[bulk])
      end

      it "answers the owner's lock refusal with today's locked JSON, for move and for discard (A9, §6.2)" do
        days = tenant_a.company.timesheet_edit_days
        fake.fail_next(:bulk_move, status: 403, slug: "entry-locked", retryable: false)
        fake.fail_next(:bulk_discard, status: 403, slug: "entry-locked", retryable: false)

        bulk_move(first)
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.update.locked", days:))

        bulk_discard(first)
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.destroy.locked", days:))

        expect(fake.entry(first.id)).to include("project_id" => tenant_a.project.id, "discarded_at" => nil)
      end

      it "never reaches tenant B's entries (§6.3)" do
        foreign = owned_entry(tenant_b)

        bulk_discard(foreign)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(writes).to be_empty
        expect(fake.entry(foreign.id)["discarded_at"]).to be_nil
      end
    end

    describe "W5 Harvest import" do
      let(:data_import) { create(:data_import, company: tenant_a.company, user: tenant_a.admin, options: {}) }

      before do
        %w[Paul\ Connors Jane\ Doe].each do |name|
          first_name, last_name = name.split
          user = create(:user, first_name:, last_name:, current_workspace_id: tenant_a.company.id)
          create(:employment, company: tenant_a.company, user:)
        end
      end

      def attach(contents) = data_import.file.attach(io: StringIO.new(contents), filename: "harvest.csv", content_type: "text/csv")

      def import! = without_projection_writes { Imports::HarvestTimeEntriesImporter.new(data_import).process }

      def harvest_rows(count, hours: 1)
        "Date,Client,Project,Hours,First Name,Last Name,Notes\n" +
          Array.new(count) { |index| "2026-01-01,Acme LLC,Website,#{hours},Paul,Connors,Row #{index}\n" }.join
      end

      it "writes every row in Timekeeping as the system import writer, billed rows billed (§3.4)" do
        attach(Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv").read)

        import!

        expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 11, failed_rows: 0)
        expect(fake.calls.map(&:operation)).to eq([:import_batch])
        expect(fake.calls.sole.claims).to include("sub" => "system", "writer" => "import", "company_id" => tenant_a.company.id)
        rows = fake.calls.sole.input.fetch("rows")
        expect(rows.size).to eq(11)
        expect(rows.pluck("bill_status")).to include("billed", "unbilled", "non_billable")
        expect((1..11).map { |id| fake.entry(id)&.fetch("company_id") }).to all(eq(tenant_a.company.id))
      end

      it "sends at most 500 rows a batch, numbered from 1 under one import id" do
        attach(harvest_rows(501))

        import!

        expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 501)
        expect(fake.calls.map { |call| call.input.fetch("rows").size }).to eq([500, 1])
        expect(fake.calls.map { |call| call.params.fetch("n") }).to eq(%w[1 2])
        expect(fake.calls.map { |call| call.params.fetch("import_id") }.uniq).to contain_exactly(start_with("#{data_import.id}-"))
      end

      it "records a row the owner rejects as today's row error, and keeps the rest of its batch" do
        attach(harvest_rows(3))
        WebMock::API.stub_request(:post, %r{/internal/v1/imports/[^/]+/batches/1\z}).to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: JSON.generate(
            "created_ids" => [1, 3],
            "failed_rows" => [{ "index" => 1, "errors" => { "duration" => ["must be less than or equal to 6000000"] } }]
          )
        )

        import!

        expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 2, failed_rows: 1)
        expect(data_import.row_errors).to eq([{ "row" => 3, "message" => "Duration must be less than or equal to 6000000" }])
      end

      it "fails the import with today's retry message when the generation moved (§9.3)" do
        attach(harvest_rows(1))
        fake.fail_next(:import_batch, status: 409, slug: "stale-generation", retryable: false)

        expect { import! }.to raise_error(Timekeeping::Ownership::Moving)
        expect(data_import.reload).to have_attributes(status: "failed", error_message: I18n.t("imports.errors.ownership_moving"))
      end
    end

    describe "W6 agent destroy" do
      let(:agent) { create(:agent, company: tenant_a.company, user: employee, default_project: tenant_a.project) }

      # An agent's entry logged under the timekeeping owner, which the relay
      # has not projected yet.
      let!(:held) do
        fake.seed_entry(
          company_id: tenant_a.company.id, project_id: tenant_a.project.id, user_id: employee.id,
          agent_id: agent.id, duration: 30.0, work_date: "2026-11-02"
        )
      end

      it "detaches the agent's entries in Timekeeping, then deletes the agent (§3.4)" do
        without_projection_writes { agent.destroy! }

        expect(Agent.exists?(agent.id)).to be(false)
        expect(fake.entry(held["id"])).to include("agent_id" => nil)
        expect(fake.calls.map(&:operation)).to eq([:detach_agent])
        expect(writers).to eq(["agent_destroy"])
      end

      it "keeps the agent when the owner refuses the detach, so nothing is half done" do
        fake.fail_next(:detach_agent, status: 409, slug: "stale-generation", retryable: false)

        without_projection_writes do
          expect { agent.destroy! }.to raise_error(Timekeeping::Ownership::Moving)
        end

        expect(Agent.exists?(agent.id)).to be(true)
        expect(fake.entry(held["id"])).to include("agent_id" => agent.id)
      end
    end
  end

  it "makes no call under the legacy owner, which still writes the table" do
    sign_in employee

    send_request :post, api_v1_timesheet_entry_index_path,
      params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(employee)

    expect(response).to have_http_status(:ok)
    expect(TimesheetEntry.find(json_response.dig("entry", "id")).note).to eq("Forwarded")
    expect(fake.calls).to be_empty
  end
end
