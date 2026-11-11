# frozen_string_literal: true

require "rails_helper"

# The single-writer guard of docs/architecture/timekeeping-soa.md §12.2, for
# the gateway in legacy mode (§10.2 step 2): every writer of §1.3 (W1-W7,
# agent destroy and the invoice callbacks included) writes timesheet_entries
# only through Timekeeping::Gateway. Each example runs one writer through its
# real entry point and asserts that it wrote, and that every write ran under
# the gateway command that writer hands it.
RSpec.describe "Timekeeping single-writer guard: every writer goes through the gateway", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  gateway = Timekeeping::Gateway

  let!(:entry) { unbilled_entry(tenant_a) }
  let(:other_project) do
    create(:project, client: tenant_a.client, billable: true).tap do |project|
      create(:project_member, project:, user: tenant_a.employee)
    end
  end
  let(:cli_token) { CliSession.issue_for(user: tenant_a.employee, company: tenant_a.company).last }
  let(:agent) { create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project) }

  def expect_only_gateway_writes(*command_classes, &writer)
    writes = timesheet_entry_writes(&writer)

    expect(writes).not_to be_empty, "the writer wrote no timesheet_entries row, so the guard proved nothing"
    expect(writes.reject(&:command)).to eq([]), "timesheet_entries written outside the gateway"
    expect(writes.map { |write| write.command.class }.uniq).to match_array(command_classes)
  end

  def entry_params
    { duration: 45, work_date: Date.current, note: "guarded", bill_status: :unbilled }
  end

  describe "W1 web" do
    before { sign_in tenant_a.employee }

    it "creates through CreateEntry" do
      expect_only_gateway_writes(gateway::CreateEntry) do
        send_request :post, api_v1_timesheet_entry_index_path,
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params },
          headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
    end

    it "updates through UpdateEntry" do
      expect_only_gateway_writes(gateway::UpdateEntry) do
        send_request :patch, api_v1_timesheet_entry_path(entry.id),
          params: { project_id: other_project.id, timesheet_entry: entry_params },
          headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
      expect(entry.reload.project_id).to eq(other_project.id)
    end

    it "discards through DiscardEntry" do
      expect_only_gateway_writes(gateway::DiscardEntry) do
        send_request :delete, api_v1_timesheet_entry_path(entry.id), headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
      expect(entry.reload).to be_discarded
    end
  end

  describe "W1 mobile" do
    before { sign_in tenant_a.employee }

    it "creates, updates and discards through the gateway" do
      expect_only_gateway_writes(gateway::CreateEntry, gateway::UpdateEntry, gateway::DiscardEntry) do
        post "/api/v1/mobile/timesheet_entries",
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params },
          headers: auth_headers(tenant_a.employee)
        id = json_response.dig("entry", "id")
        patch "/api/v1/mobile/timesheet_entries/#{id}",
          params: { project_id: tenant_a.project.id, timesheet_entry: entry_params.merge(note: "edited") },
          headers: auth_headers(tenant_a.employee)
        delete "/api/v1/mobile/timesheet_entries/#{id}", headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
    end
  end

  describe "W2 bulk" do
    before { sign_in tenant_a.employee }

    it "moves through BulkMove" do
      expect_only_gateway_writes(gateway::BulkMove) do
        send_request :patch, api_v1_bulk_action_path,
          params: { ids: [entry.id], project_id: other_project.id },
          headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
      expect(entry.reload.project_id).to eq(other_project.id)
    end

    it "discards through BulkDiscard" do
      expect_only_gateway_writes(gateway::BulkDiscard) do
        send_request :delete, api_v1_bulk_action_path,
          params: { source: { ids: [entry.id] } },
          headers: auth_headers(tenant_a.employee)
      end
      expect(response).to have_http_status(:ok)
      expect(entry.reload).to be_discarded
    end
  end

  describe "W3 CLI" do
    def cli_params(**overrides)
      { timesheet_entry: { project_id: tenant_a.project.id, duration_minutes: 30, work_date: Date.current.iso8601, **overrides } }
    end

    it "creates, updates and discards through the gateway" do
      expect_only_gateway_writes(gateway::CreateEntry, gateway::UpdateEntry, gateway::DiscardEntry) do
        send_request :post, api_v1_cli_timesheet_entries_path, params: cli_params, headers: cli_auth_headers(cli_token)
        id = json_response.dig("entry", "id")
        send_request :patch, api_v1_cli_timesheet_entry_path(id), params: cli_params(note: "edited"), headers: cli_auth_headers(cli_token)
        send_request :delete, api_v1_cli_timesheet_entry_path(id), headers: cli_auth_headers(cli_token)
      end
      expect(response).to have_http_status(:ok)
    end
  end

  describe "W3a MCP, in-process through W3" do
    it "creates through CreateEntry" do
      result = nil
      expect_only_gateway_writes(gateway::CreateEntry) do
        result = MCP::Miru::Tools::TimeCreateTool.call(
          project_id: tenant_a.project.id, duration_minutes: 30, work_date: Date.current.iso8601,
          server_context: { authorization: cli_token }
        )
      end
      expect(result.error?).to be(false)
    end
  end

  describe "W4 agent" do
    let(:agent_token) { AgentKey.issue_for(agent:, name: "Guard", created_by: tenant_a.admin).last }

    it "creates through CreateEntry" do
      expect_only_gateway_writes(gateway::CreateEntry) do
        send_request :post, api_v1_agent_timesheet_entries_path,
          params: { timesheet_entry: { duration_minutes: 30, work_date: Date.current.iso8601 } },
          headers: { "Authorization" => "Bearer #{agent_token}" }
      end
      expect(response).to have_http_status(:ok)
    end
  end

  describe "W5 Harvest import" do
    it "creates every row through ImportEntry, billed rows included" do
      %w[Paul\ Connors Jane\ Doe].each do |name|
        first_name, last_name = name.split
        user = create(:user, first_name:, last_name:, current_workspace_id: tenant_a.company.id)
        create(:employment, company: tenant_a.company, user:)
      end
      data_import = create(:data_import, company: tenant_a.company, user: tenant_a.admin, options: {})
      path = Rails.root.join("spec/fixtures/files/harvest_detailed_time.csv")
      File.open(path) { |file| data_import.file.attach(io: file, filename: File.basename(path), content_type: "text/csv") }

      expect_only_gateway_writes(gateway::ImportEntry) { Imports::HarvestTimeEntriesImporter.new(data_import).process }
      expect(data_import.reload).to have_attributes(status: "completed", imported_rows: 11)
      expect(tenant_a.company.timesheet_entries.where(bill_status: :billed)).to exist
    end
  end

  describe "W6 agent destroy" do
    it "detaches the agent's entries through DetachAgent" do
      agent_entry = unbilled_entry(tenant_a, agent:)

      expect_only_gateway_writes(gateway::DetachAgent) { agent.destroy! }
      expect(agent_entry.reload.agent_id).to be_nil
    end
  end

  describe "W7 invoice callbacks" do
    let(:invoice) { invoice_for(tenant_a) }

    before { direct_line(invoice, entry) }

    it "locks on draft save, through SetLocked" do
      # Adding the line already saved the draft (its totals sync), so clear
      # the lock first; otherwise the save below has nothing to write.
      entry.update_column(:locked, false)

      expect_only_gateway_writes(gateway::SetLocked) { invoice.reload.save! }
      expect(locked?(entry)).to be(true)
    end

    it "unlocks on draft discard and re-locks on its number update (K2), through SetLocked" do
      invoice.reload.save!

      expect_only_gateway_writes(gateway::SetLocked) { invoice.discard! }
      expect(locked?(entry)).to be(true)
    end

    it "unlocks on a draft line-item destroy, through SetLocked" do
      invoice.reload.save!

      expect_only_gateway_writes(gateway::SetLocked) { invoice.invoice_line_items.first.destroy! }
      expect(locked?(entry)).to be(false)
    end

    it "marks billed through MarkBilled" do
      expect_only_gateway_writes(gateway::MarkBilled) { invoice.reload.update_timesheet_entry_status! }
      expect(entry.reload).to be_billed
    end
  end

  describe "the guard itself" do
    it "reports a write that bypasses the gateway" do
      writes = timesheet_entry_writes { entry.update_column(:note, "bypass") }

      expect(writes.size).to eq(1)
      expect(writes.first.command).to be_nil
    end
  end
end
