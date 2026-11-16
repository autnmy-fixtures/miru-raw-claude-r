# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §3.4 and §10.2 step 3, for W6: the
# key from timesheet_entries to agents is dropped before cutover. Once entries
# leave the legacy owner, the agent is deleted after the owner acknowledges the
# detach, while the projection can still name it until the relay delivers.
# The key to users stays (§10.1).
RSpec.describe "Timekeeping: entry references to agents", type: :model do
  include_context "with two Timekeeping tenants"

  let(:connection) { ActiveRecord::Base.connection }
  let(:agent) { create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project) }

  def keys_to(target)
    connection.foreign_keys("timesheet_entries").select { |key| key.to_table == target }
  end

  describe "the schema" do
    it "has no key from timesheet_entries to agents, and keeps its index" do
      expect(keys_to("agents")).to be_empty
      expect(connection.index_exists?(:timesheet_entries, :agent_id)).to be(true)
    end

    it "keeps the keys to users and projects" do
      expect(keys_to("users").size).to eq(1)
      expect(keys_to("projects").size).to eq(1)
    end
  end

  # The projection consumer writes rows as Timekeeping decided them, with no
  # model rule (§3.2), so a row can name an agent deleted a moment before.
  it "reads a row naming a deleted agent as having no agent" do
    entry = unbilled_entry(tenant_a)
    agent_id = agent.id
    agent.delete
    TimesheetEntry.where(id: entry.id).update_all(agent_id:)

    row = TimesheetEntry.find(entry.id)
    expect(row.agent_id).to eq(agent_id)
    expect(row.agent).to be_nil
    expect(row.snippet).to include(agent_id:, agent_name: nil)
  end

  # Under the legacy owner the gateway still nulls the agent's entries before
  # the delete, as today (K8), so no row is left naming it.
  it "still detaches the agent's entries before the delete under the legacy owner (K8)" do
    entry = unbilled_entry(tenant_a, agent:)

    agent.destroy!

    expect(entry.reload.agent_id).to be_nil
  end
end
