# frozen_string_literal: true

require "rails_helper"

# Characterization: pins entry-writer behaviour the existing suite does not
# (docs/architecture/timekeeping-soa.md §1.3, §2.1, §12.1, Appendix A K8,
# K10, K12, K13). Today's behaviour, quirks included; the extraction preserves
# every case here.
RSpec.describe "Timekeeping characterization: entry writers", type: :request do
  include_context "with two Timekeeping tenants"

  describe "A9 / K12: bulk move by an employee" do
    let(:entry) { unbilled_entry(tenant_a) }
    let(:other_project) do
      create(:project, client: tenant_a.client, billable: true).tap do |project|
        create(:project_member, project:, user: tenant_a.employee)
      end
    end

    it "answers 200 and silently leaves a locked, unbilled, in-window entry unmoved" do
      entry.update_column(:locked, true)

      sign_in tenant_a.employee
      send_request :patch, api_v1_bulk_action_path,
        params: { ids: [entry.id], project_id: other_project.id },
        headers: auth_headers(tenant_a.employee)

      expect(response).to have_http_status(:ok)
      expect(entry.reload.project_id).to eq(tenant_a.project.id)
    end
  end

  describe "A11 / K13: bill_status through the web API" do
    let(:entry) { unbilled_entry(tenant_a) }

    def update_entry(bill_status)
      send_request :patch, api_v1_timesheet_entry_path(entry.id), params: {
        project_id: tenant_a.project.id,
        timesheet_entry: { duration: entry.duration, work_date: entry.work_date, note: entry.note, bill_status: }
      }, headers: auth_headers(tenant_a.employee)
    end

    it "lets an employee mark their own entry billed, and then refuses any further edit (A3)" do
      sign_in tenant_a.employee

      update_entry("billed")
      expect(response).to have_http_status(:ok)
      expect(entry.reload.bill_status).to eq("billed")

      update_entry("unbilled")
      expect(response).to have_http_status(:forbidden)
      expect(entry.reload.bill_status).to eq("billed")
    end
  end

  describe "A10 / K10: agent entries" do
    let(:agent) { create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project) }
    let(:agent_token) { AgentKey.issue_for(agent:, name: "Characterization", created_by: tenant_a.admin).last }

    def post_agent_entry(external_run_id:)
      send_request :post, api_v1_agent_timesheet_entries_path, params: {
        timesheet_entry: {
          duration_minutes: 30,
          work_date: Date.current.iso8601,
          note: "agent work",
          source_metadata: { tool: "claude-code", mcp_server: "miru" },
          external_run_id:
        }
      }, headers: { "Authorization" => "Bearer #{agent_token}" }
    end

    it "stores source mcp when source_metadata names an mcp_server, forces pending_review, and does not dedupe external_run_id" do
      2.times { post_agent_entry(external_run_id: "run-1") }

      expect(response).to have_http_status(:ok)
      entries = TimesheetEntry.where(agent_id: agent.id)
      expect(entries.count).to eq(2)
      expect(entries.pluck(:source).uniq).to eq(["mcp"])
      expect(entries.pluck(:review_status).uniq).to eq(["pending_review"])
      expect(entries.pluck(:user_id).uniq).to eq([tenant_a.employee.id])
    end
  end

  describe "W6 / K8: agent destroy" do
    it "nulls agent_id on the agent's entries and keeps the entries" do
      agent = create(:agent, company: tenant_a.company, user: tenant_a.employee)
      entry = unbilled_entry(tenant_a, agent:)

      agent.destroy!

      expect(entry.reload.agent_id).to be_nil
      expect(entry.discarded_at).to be_nil
    end
  end
end
