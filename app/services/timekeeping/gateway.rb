# frozen_string_literal: true

# The write gateway of docs/architecture/timekeeping-soa.md §3.1: the one
# module through which every writer of timesheet_entries (§1.3, W1-W7) changes
# entry state. Controllers, the import, agent destroy and the invoice
# callbacks authenticate and authorize as today, then hand it a command. The
# gateway sends the command to the owner the ownership record names (§10.1).
#
# Only the legacy owner exists so far (§10.2 step 2): it runs today's model
# code unchanged. The timekeeping and monolith owners arrive with their lanes.
# Until then a command under either is refused, never written locally,
# because a local write there would be a second writer.
module Timekeeping::Gateway
  class OwnerUnavailable < StandardError; end

  # Entry commands (W1 web and mobile, W3 CLI and so W3a MCP, W4 agent).
  CreateEntry = Data.define(:project, :user, :attributes)
  UpdateEntry = Data.define(:entry, :project, :attributes)
  DiscardEntry = Data.define(:entry)

  # W2 bulk move and bulk delete. `entries` is the caller's relation, so the
  # response renders exactly the records the command touched (A9).
  BulkMove = Data.define(:entries, :project)
  BulkDiscard = Data.define(:entries)

  # W5 Harvest import, one row. `billed` rows are created unbilled and then
  # marked billed, as today (§1.3).
  ImportEntry = Data.define(:company, :attributes, :billed)

  # W6 agent destroy: replaces `dependent: :nullify` on Agent.
  DetachAgent = Data.define(:agent)

  # W7 the invoice callbacks, until the invoice boundary replaces them (§7).
  SetLocked = Data.define(:entries, :locked)
  MarkBilled = Data.define(:entries)

  OWNERS = { "legacy" => Timekeeping::Gateway::Legacy }.freeze

  COMMAND_KEY = :timekeeping_gateway_command
  private_constant :COMMAND_KEY

  def self.call(command)
    owner = Timekeeping::Ownership.current.owner
    handler = OWNERS.fetch(owner) do
      raise OwnerUnavailable, "Timekeeping gateway: owner #{owner} is not available yet, #{command.class.name.demodulize} refused"
    end

    within(command) { handler.call(command) }
  end

  # The command this execution context is running, or nil. The single-writer
  # guard (§12.2) reads it to tell a gateway write from any other.
  def self.current_command
    ActiveSupport::IsolatedExecutionState[COMMAND_KEY]
  end

  def self.within(command)
    outer = current_command
    ActiveSupport::IsolatedExecutionState[COMMAND_KEY] = command
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[COMMAND_KEY] = outer
  end
  private_class_method :within
end
