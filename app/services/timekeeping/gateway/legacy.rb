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
    gateway::ImportBatch => ->(command) {
      created_ids = []
      row_errors = {}
      command.rows.each_with_index do |attributes, index|
        created_ids << ActiveRecord::Base.transaction(requires_new: true) { import_row(command.company, attributes) }.id
      rescue ActiveRecord::RecordInvalid => error
        row_errors[index] = error.record.errors.full_messages.to_sentence
      end
      gateway::ImportBatch::Result.new(created_ids:, row_errors:)
    },
    gateway::DetachAgent => ->(command) { TimesheetEntry.where(agent_id: command.agent.id).update_all(agent_id: nil) },
    gateway::SetLocked => ->(command) { command.entries.update!(locked: command.locked) },
    gateway::MarkBilled => ->(command) { command.entries.update!(bill_status: :billed) }
  }.freeze

  def self.handles?(command) = HANDLERS.key?(command.class)

  # Today's code reads no ownership: the fence already admitted the command.
  def self.call(command, _ownership)
    HANDLERS.fetch(command.class).call(command)
  end

  # One Harvest row, in its own savepoint: the model refuses to create an
  # entry billed, so a billed row is created unbilled and then marked billed.
  def self.import_row(company, attributes)
    billed = attributes.fetch(:bill_status).to_s == "billed"
    created = TimesheetEntry.create!(attributes.merge(bill_status: billed ? "unbilled" : attributes.fetch(:bill_status))) do |entry|
      entry.association(:company).target = company
    end
    created.tap { |entry| entry.update!(bill_status: :billed) if billed }
  end
  private_class_method :import_row
end
