# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §3.4 and §10.2 step 3, for W6: once
# entries leave the legacy owner, the existing application destroys an agent
# after the owner acknowledges the detach (§3.4), but timesheet_entries is a
# projection that can lag. This key would then refuse the delete while a
# projected row still names the agent, and an older snapshot naming a deleted
# agent would stall the relay on it, as §10.1 describes for users. So it is
# dropped before cutover, like the two billing keys (20261111130000). Under the
# legacy owner the gateway still nulls agent_id before the delete, as today
# (K8). The index stays. TimesheetEntry#agent is optional, so a row that names
# a deleted agent until the relay delivers the detach reads as no agent.
class DropTimesheetEntriesAgentsForeignKey < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :timesheet_entries, :agents
  end
end
