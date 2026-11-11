# frozen_string_literal: true

require "rails_helper"

# The generation fence of docs/architecture/timekeeping-soa.md §10.1, writer
# by writer: while a handoff has admission closed, every writer of §1.3
# (W1-W7) is refused through its real entry point, writes no
# timesheet_entries row, and tells the caller to retry: a 503
# ownership-moving over HTTP (MCP included), a failed import that says so,
# and a raised refusal for agent destroy. The single-writer guard spec runs
# the same writers with admission open.
RSpec.describe "Timekeeping generation fence: writers are refused while admission is closed", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let(:moving) { I18n.t("timesheet_entry.ownership_moving") }
  let!(:entry) { unbilled_entry(tenant_a) }
  let(:cli_token) { CliSession.issue_for(user: tenant_a.employee, company: tenant_a.company).last }
  let(:agent) { create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project) }

  def close_admission!
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed"))
  end

  def expect_refused_without_writes(&writer)
    writes = timesheet_entry_writes(&writer)

    expect(writes).to eq([]), "timesheet_entries written while admission was closed"
  end

  def expect_retryable_refusal
    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["errors"]).to eq(moving)
  end

  def entry_params
    { duration: 45, work_date: Date.current, note: "fenced", bill_status: :unbilled }
  end

  describe "W1 web and mobile" do
    before do
      sign_in tenant_a.employee
      close_admission!
    end

    it "refuses create, update and discard" do
      expect_refused_without_writes do
        send_request :post, api_v1_timesheet_entry_index_path,
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(tenant_a.employee)
        expect_retryable_refusal

        send_request :patch, api_v1_timesheet_entry_path(entry.id),
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(tenant_a.employee)
        expect_retryable_refusal

        send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(tenant_a.employee)
        expect_retryable_refusal
      end
      expect(entry.reload).to have_attributes(note: entry.note, discarded_at: nil)
    end

    it "refuses a mobile create" do
      expect_refused_without_writes do
        post "/api/v1/mobile/timesheet_entries",
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params }, headers: auth_headers(tenant_a.employee)
      end
      expect_retryable_refusal
    end
  end

  describe "W2 bulk" do
    before do
      sign_in tenant_a.employee
      close_admission!
    end

    it "refuses a bulk move and a bulk discard" do
      expect_refused_without_writes do
        send_request :patch, api_v1_bulk_action_path,
          params: { ids: [entry.id], project_id: tenant_a.project.id }, headers: auth_headers(tenant_a.employee)
        expect_retryable_refusal

        send_request :delete, api_v1_bulk_action_path,
          params: { source: { ids: [entry.id] } }, headers: auth_headers(tenant_a.employee)
        expect_retryable_refusal
      end
      expect(entry.reload).not_to be_discarded
    end
  end

  describe "W3 CLI and W3a MCP" do
    let(:cli_params) do
      { timesheet_entry: { project_id: tenant_a.project.id, duration_minutes: 30, work_date: Date.current.iso8601 } }
    end

    before { close_admission! }

    it "refuses a CLI create" do
      expect_refused_without_writes do
        send_request :post, api_v1_cli_timesheet_entries_path, params: cli_params, headers: cli_auth_headers(cli_token)
      end
      expect_retryable_refusal
    end

    it "returns the 503 to an MCP tool call as an error" do
      result = nil
      expect_refused_without_writes do
        result = MCP::Miru::Tools::TimeCreateTool.call(
          project_id: tenant_a.project.id, duration_minutes: 30, work_date: Date.current.iso8601,
          server_context: { authorization: cli_token }
        )
      end

      expect(result.error?).to be(true)
      expect(JSON.parse(result.content.first[:text])).to include("status" => 503, "data" => { "errors" => moving })
    end
  end

  describe "W4 agent" do
    let(:agent_token) { AgentKey.issue_for(agent:, name: "Fence", created_by: tenant_a.admin).last }

    it "refuses an agent create" do
      agent_token
      close_admission!

      expect_refused_without_writes do
        send_request :post, api_v1_agent_timesheet_entries_path,
          params: { timesheet_entry: { duration_minutes: 30, work_date: Date.current.iso8601 } },
          headers: { "Authorization" => "Bearer #{agent_token}" }
      end
      expect_retryable_refusal
    end
  end

  describe "W5 Harvest import" do
    it "fails the import with a retry message and keeps none of the refused batch" do
      %w[Paul\ Connors Jane\ Doe].each do |name|
        first_name, last_name = name.split
        user = create(:user, first_name:, last_name:, current_workspace_id: tenant_a.company.id)
        create(:employment, company: tenant_a.company, user:)
      end
      data_import = create(:data_import, company: tenant_a.company, user: tenant_a.admin, options: {})
      path = Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")
      File.open(path) { |file| data_import.file.attach(io: file, filename: File.basename(path), content_type: "text/csv") }
      close_admission!

      expect_refused_without_writes do
        expect { Imports::HarvestTimeEntriesImporter.new(data_import).process }
          .to raise_error(Timekeeping::Ownership::Moving)
      end
      expect(data_import.reload).to have_attributes(status: "failed", error_message: I18n.t("imports.errors.ownership_moving"))
    end
  end

  describe "W6 agent destroy" do
    it "refuses the destroy, so the agent and its entries stay as they were" do
      agent_entry = unbilled_entry(tenant_a, agent:)
      close_admission!

      expect_refused_without_writes do
        expect { agent.destroy! }.to raise_error(Timekeeping::Ownership::Moving)
      end
      expect(Agent.exists?(agent.id)).to be(true)
      expect(agent_entry.reload.agent_id).to eq(agent.id)
    end
  end

  describe "W7 invoice callbacks" do
    let(:invoice) { invoice_for(tenant_a) }

    before do
      direct_line(invoice, entry)
      invoice.reload.save!
    end

    it "refuses a draft discard through the invoice API, and the draft stays kept and its entry locked" do
      sign_in tenant_a.admin
      close_admission!

      expect_refused_without_writes do
        send_request :delete, api_v1_invoice_path(id: invoice.id), headers: auth_headers(tenant_a.admin)
      end
      expect_retryable_refusal
      expect(invoice.reload).not_to be_discarded
      expect(locked?(entry)).to be(true)
    end
  end
end
