# frozen_string_literal: true

require "rails_helper"

# Entry creates under the `monolith` owner (docs/architecture/timekeeping-soa.md
# §3.1, §10.5), through the real entry points of W1 web, W3 CLI, W3a MCP and
# W4 agent: each lands in the prepared application's own entry table with its
# audit and outbox rows, answers today's public JSON, and writes nothing to
# timesheet_entries, which the local relay then projects (§3.2, §12.2).
# Update and discard go through the same owner once the entry reads under
# `monolith` exist; gateway_local_spec.rb covers them at the gateway.
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
end
