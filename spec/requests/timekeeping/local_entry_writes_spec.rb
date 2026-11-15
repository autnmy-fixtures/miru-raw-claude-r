# frozen_string_literal: true

require "rails_helper"

# Entry writes and reads under the `monolith` owner
# (docs/architecture/timekeeping-soa.md §3.1, §3.3 rule 1, §10.5), through
# the real entry points of W1 web and mobile, W2 bulk, W3 CLI, W3a MCP and
# W4 agent: each write lands in the prepared application's own entry table
# with its audit and outbox rows, answers today's public JSON, and writes
# nothing to timesheet_entries, which the local relay then projects (§3.2,
# §12.2). The time-tracking list, the lookup before an update or discard and
# W2's selection read that same table, so an entry the relay has not
# projected yet is listed and edited at once (§12.4 "relay paused"),
# authorized on the owner's state.
RSpec.describe "Timekeeping entry writes under the monolith owner", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let(:employee) { tenant_a.employee }
  let(:cli_token) { CliSession.issue_for(user: employee, company: tenant_a.company).last }

  before do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
    advance_local_entry_ids!
  end

  def without_projection_writes(&writer)
    writes = timesheet_entry_writes(&writer)
    expect(writes).to eq([]), "a monolith write wrote timesheet_entries"
  end

  def held(id) = Timekeeping::Entry.find(id)

  it "W1 web creates in the prepared application's table and renders today's JSON" do
    sign_in employee

    without_projection_writes do
      send_request :post, api_v1_timesheet_entry_index_path,
        params: { project_id: tenant_a.project.id, timesheet_entry: { duration: 90.7, work_date: "2026-11-02", note: "Local", bill_status: "unbilled" } },
        headers: auth_headers(employee)
    end

    expect(response).to have_http_status(:ok)
    expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.create.message"))
    entry = held(json_response.dig("entry", "id"))
    expect(entry).to have_attributes(company_id: tenant_a.company.id, user_id: employee.id, duration: 90.7, note: "Local")
    expect(json_response["entry"]).to include(
      "id" => entry.id, "project" => tenant_a.project.name, "client" => tenant_a.client.name, "duration" => 90.7,
      "note" => "Local", "work_date" => "2026-11-02", "bill_status" => "unbilled", "team_member" => employee.full_name,
      "type" => "timesheet"
    )
    expect(entry.audits.sole.writer).to eq("web")
    expect(entry.outbox_snapshots.count).to eq(1)
    expect(TimesheetEntry.where(id: entry.id)).to be_empty
  end

  it "W1 web answers a model refusal with today's 422 shape, and writes nothing" do
    sign_in employee

    send_request :post, api_v1_timesheet_entry_index_path,
      params: { project_id: tenant_a.project.id, timesheet_entry: { duration: 6_000_001, work_date: "2026-11-02", bill_status: "unbilled" } },
      headers: auth_headers(employee)

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq("Duration must be less than or equal to 6000000")
    expect(Timekeeping::Entry.count).to eq(0)
  end

  it "W3 CLI and W3a MCP create as their writers" do
    without_projection_writes do
      send_request :post, api_v1_cli_timesheet_entries_path,
        params: { timesheet_entry: { project_id: tenant_a.project.id, duration_minutes: 30, work_date: "2026-11-02" } },
        headers: cli_auth_headers(cli_token)
      expect(response).to have_http_status(:ok)
      expect(json_response["entry"]).to include("source" => "cli", "duration" => 30.0)

      result = MCP::Miru::Tools::TimeCreateTool.call(
        project_id: tenant_a.project.id, duration_minutes: 30, work_date: "2026-11-02", server_context: { authorization: cli_token }
      )
      expect(result.error?).to be(false)
    end

    expect(Timekeeping::EntryAudit.order(:id).pluck(:writer)).to eq(%w[cli mcp])
  end

  it "W4 agent creates as the agent, pending review" do
    agent = create(:agent, company: tenant_a.company, user: employee, default_project: tenant_a.project)
    agent_token = AgentKey.issue_for(agent:, name: "Local", created_by: tenant_a.admin).last

    without_projection_writes do
      send_request :post, api_v1_agent_timesheet_entries_path,
        params: { timesheet_entry: { duration_minutes: 30, work_date: "2026-11-02", note: "Agent run" } },
        headers: { "Authorization" => "Bearer #{agent_token}" }
    end

    expect(response).to have_http_status(:ok)
    expect(json_response["entry"]).to include("agent_id" => agent.id, "agent_name" => agent.name, "source" => "automation")
    expect(held(json_response.dig("entry", "id"))).to have_attributes(agent_id: agent.id, user_id: employee.id, review_status: "pending_review")
  end

  it "reaches the projection once the local relay runs" do
    sign_in employee
    send_request :post, api_v1_timesheet_entry_index_path,
      params: { project_id: tenant_a.project.id, timesheet_entry: { duration: 90.7, work_date: "2026-11-02", note: "Local", bill_status: "unbilled" } },
      headers: auth_headers(employee)
    entry = held(json_response.dig("entry", "id"))

    Timekeeping::LocalRelay.new.run

    expect(Timekeeping::StoredEntries.all.find { |row| row.fetch("id") == entry.id }).to eq(entry.to_contract)
  end

  describe "reads and edits from the prepared application's table" do
    let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }
    let(:november) { { from: "2026-11-01", to: "2026-11-30" } }

    # An entry the prepared application holds that the relay has not
    # projected: no timesheet_entries row holds it (§12.4 "relay paused").
    def held_entry(tenant, offset: 0, user: tenant.employee, **attributes)
      Timekeeping::Entry.create!(
        id: first_id + offset, company_id: tenant.company.id, project_id: tenant.project.id, user_id: user.id,
        duration: 60.0, work_date: Date.current, note: "Before", bill_status: "unbilled", **attributes
      )
    end

    def list(path: api_v1_timesheet_entry_index_path, user: employee)
      send_request :get, path, params: november, headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      json_response.fetch("entries")
    end

    def listed_ids(entries) = entries.values.flatten.pluck("id")

    # Runs the block and fails if anything read timesheet_entries.
    def without_projection_reads(&reader)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?(%("timesheet_entries")) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &reader)
      expect(queries).to eq([]), "the request read the projection"
    end

    it "W1 lists the owner's entries with today's JSON, on the web and mobile routes and for MCP's miru.time.list" do
      sign_in employee
      older = held_entry(tenant_a, offset: 0, work_date: Date.new(2026, 11, 2), duration: 90.7, note: "Older")
      newer = held_entry(tenant_a, offset: 1, work_date: Date.new(2026, 11, 4), note: "Newer", source: "cli")
      held_entry(tenant_a, offset: 2, work_date: Date.new(2026, 11, 3), discarded_at: Time.current)
      held_entry(tenant_b, offset: 3, user: tenant_b.employee, work_date: Date.new(2026, 11, 3))

      entries = nil
      without_projection_reads { entries = list }

      expect(entries.keys).to eq(%w[2026-11-04 2026-11-02])
      expect(entries.fetch("2026-11-02").sole).to include(
        "id" => older.id, "duration" => 90.7, "note" => "Older", "type" => "timesheet", "bill_status" => "unbilled",
        "project" => tenant_a.project.name, "project_id" => tenant_a.project.id, "client" => tenant_a.client.name,
        "team_member" => employee.full_name
      )
      expect(listed_ids(list(path: "/api/v1/mobile/timesheet_entries"))).to eq([newer.id, older.id])
      result = MCP::Miru::Tools::TimeListTool.call(**november, server_context: { authorization: cli_token })
      expect(result.error?).to be(false)
      expect(listed_ids(JSON.parse(result.content.sole[:text]).dig("data", "entries"))).to eq([newer.id, older.id])
    end

    it "W1 edits and discards an entry the projection does not hold, in the owner's table" do
      sign_in employee
      entry = held_entry(tenant_a)

      without_projection_writes do
        send_request :patch, api_v1_timesheet_entry_path(entry.id), params: {
          project_id: tenant_a.project.id, timesheet_entry: { duration: 45, work_date: Date.current.iso8601, note: "Edited" }
        }, headers: auth_headers(employee)
        expect(response).to have_http_status(:ok)
        expect(json_response["entry"]).to include("id" => entry.id, "note" => "Edited", "duration" => 45.0)

        send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(employee)
        expect(response).to have_http_status(:ok)
        expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
      end

      expect(entry.reload).to have_attributes(version: 3, note: "Edited", duration: 45.0, discarded_at: be_present)
      expect(entry.audits.order(:id).pluck(:action, :writer)).to eq([%w[update web], %w[update web]])
      expect(TimesheetEntry.where(id: entry.id)).to be_empty
    end

    it "W1 judges the edit lock on the owner's state: an entry its reservations lock is refused to an employee (L1, §7.1)" do
      sign_in employee
      entry = held_entry(tenant_a)
      Timekeeping::Reservation.create!(
        entry_id: entry.id, invoice_id: 10, company_id: tenant_a.company.id, state: "committed", disposition: "active", edit_lock: true
      )

      send_request :patch, api_v1_timesheet_entry_path(entry.id), params: {
        project_id: tenant_a.project.id, timesheet_entry: { duration: 45, work_date: Date.current.iso8601, note: "Edited" }
      }, headers: auth_headers(employee)

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response["errors"]).to eq("Cannot edit a locked timesheet entry. Please contact admin.")
      expect(entry.reload).to have_attributes(version: 1, note: "Before")
    end

    it "W1 authorizes on the owner's state: an entry the owner holds billed is refused (A3)" do
      sign_in employee
      entry = held_entry(tenant_a, bill_status: "billed")

      send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(employee)

      expect(response).to have_http_status(:forbidden)
      expect(entry.reload).to have_attributes(version: 1, discarded_at: nil)
    end

    it "W1 answers today's not-found for an entry the owner does not hold kept in the company (§6.3)" do
      sign_in employee
      foreign = held_entry(tenant_b, offset: 0, user: tenant_b.employee)
      discarded = held_entry(tenant_a, offset: 1, discarded_at: Time.current)

      [foreign.id, discarded.id, "not-an-id"].each do |id|
        send_request :delete, api_v1_timesheet_entry_path(id), headers: auth_headers(employee)
        expect(response).to have_http_status(:not_found)
      end
      expect(foreign.reload).to have_attributes(version: 1, discarded_at: nil)
    end

    it "W3 CLI edits and W3a MCP discards the caller's own entry, and another member's is not-found (A7)" do
      entry = held_entry(tenant_a)
      theirs = held_entry(tenant_a, offset: 1, user: tenant_a.admin)

      without_projection_writes do
        send_request :patch, api_v1_cli_timesheet_entry_path(entry.id), params: { timesheet_entry: {
          project_id: tenant_a.project.id, duration_minutes: 45, work_date: Date.current.iso8601, note: "edited"
        } }, headers: cli_auth_headers(cli_token)
        expect(response).to have_http_status(:ok)
        result = MCP::Miru::Tools::TimeDeleteTool.call(id: entry.id, server_context: { authorization: cli_token })
        expect(result.error?).to be(false)
      end
      send_request :delete, api_v1_cli_timesheet_entry_path(theirs.id), headers: cli_auth_headers(cli_token)

      expect(response).to have_http_status(:not_found)
      expect(entry.reload).to have_attributes(note: "edited", discarded_at: be_present)
      expect(entry.audits.order(:id).pluck(:writer)).to eq(%w[cli mcp])
      expect(theirs.reload.discarded_at).to be_nil
    end

    describe "W2 bulk" do
      let(:target) do
        create(:project, client: tenant_a.client, billable: true).tap do |project|
          create(:project_member, project:, user: employee)
        end
      end

      before { sign_in employee }

      def bulk_move(*entries)
        send_request :patch, api_v1_bulk_action_path,
          params: { ids: entries.map(&:id), project_id: target.id }, headers: auth_headers(employee)
      end

      def bulk_discard(*entries)
        send_request :delete, api_v1_bulk_action_path, params: { source: { ids: entries.map(&:id) } }, headers: auth_headers(employee)
      end

      it "moves and then discards entries the projection does not hold, in the owner's table, with today's JSON" do
        first = held_entry(tenant_a, offset: 0, note: "First")
        second = held_entry(tenant_a, offset: 1, note: "Second")

        without_projection_writes do
          bulk_move(first, second)
          expect(response).to have_http_status(:ok)
          expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.update.message"))
          expect(json_response["entries"].values.flatten.map { |entry| [entry["id"], entry["project_id"], entry["project"]] })
            .to contain_exactly([first.id, target.id, target.name], [second.id, target.id, target.name])

          bulk_discard(first)
          expect(response).to have_http_status(:ok)
          expect(json_response["notice"]).to eq(I18n.t("timesheet_entry.destroy.message"))
        end

        expect(first.reload).to have_attributes(project_id: target.id, version: 3, discarded_at: be_present)
        expect(second.reload).to have_attributes(project_id: target.id, version: 2, discarded_at: nil)
        expect(first.audits.order(:id).pluck(:writer)).to eq(%w[bulk bulk])
        expect(TimesheetEntry.where(id: [first.id, second.id])).to be_empty
      end

      it "skips an employee's entry its reservations lock, and still answers 200 (A9's silent skip, K12, §7.1)" do
        locked = held_entry(tenant_a, offset: 0)
        free = held_entry(tenant_a, offset: 1)
        Timekeeping::Reservation.create!(
          entry_id: locked.id, invoice_id: 10, company_id: tenant_a.company.id, state: "committed", disposition: "active", edit_lock: true
        )

        bulk_move(locked, free)

        expect(response).to have_http_status(:ok)
        expect(locked.reload).to have_attributes(project_id: tenant_a.project.id, version: 1)
        expect(free.reload).to have_attributes(project_id: target.id, version: 2)
      end

      it "answers today's locked JSON for an entry the owner holds billed, for move and for discard, and writes nothing (A9)" do
        days = tenant_a.company.timesheet_edit_days
        billed = held_entry(tenant_a, bill_status: "billed")

        bulk_move(billed)
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.update.locked", days:))

        bulk_discard(billed)
        expect(response).to have_http_status(:forbidden)
        expect(json_response).to eq("error" => I18n.t("timesheet_entry.destroy.locked", days:))

        expect(billed.reload).to have_attributes(version: 1, project_id: tenant_a.project.id, discarded_at: nil)
      end

      it "never reaches tenant B's entries (§6.3)" do
        foreign = held_entry(tenant_b, user: tenant_b.employee)

        bulk_discard(foreign)

        expect(response).to have_http_status(:unprocessable_content)
        expect(foreign.reload).to have_attributes(version: 1, discarded_at: nil)
        expect(Timekeeping::OutboxSnapshot.count).to eq(0)
      end
    end
  end
end
