# frozen_string_literal: true

# The `legacy` owner of the gateway (docs/architecture/timekeeping-soa.md
# §3.1): entry writes go to today's model code and reservations to today's
# callbacks. Each handler is the code its writer ran before the gateway
# existed, moved here unchanged, so routing a writer through the gateway
# changes no behaviour (§10.2 step 2).
module Timekeeping::Gateway::Legacy
  gateway = Timekeeping::Gateway

  HANDLERS = {
    gateway::CreateEntry => ->(command) {
      command.project.timesheet_entries.new(command.attributes).tap do |entry|
        entry.user = command.user
        entry.save!
      end
    },
    gateway::UpdateEntry => ->(command) {
      command.entry.tap do |entry|
        entry.project = command.project
        entry.update!(command.attributes)
      end
    },
    gateway::DiscardEntry => ->(command) { command.entry.discard! },
    gateway::BulkMove => ->(command) { command.entries.update(project_id: command.project.id) },
    gateway::BulkDiscard => ->(command) { command.entries.discard_all },
    gateway::ImportEntry => ->(command) {
      TimesheetEntry.create!(command.attributes) { |entry| entry.association(:company).target = command.company }.tap do |entry|
        entry.update!(bill_status: :billed) if command.billed
      end
    },
    gateway::DetachAgent => ->(command) { TimesheetEntry.where(agent_id: command.agent.id).update_all(agent_id: nil) },
    gateway::SetLocked => ->(command) { command.entries.update!(locked: command.locked) },
    gateway::MarkBilled => ->(command) { command.entries.update!(bill_status: :billed) }
  }.freeze

  def self.call(command)
    HANDLERS.fetch(command.class).call(command)
  end
end
