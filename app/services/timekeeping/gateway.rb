# frozen_string_literal: true

# The write gateway of docs/architecture/timekeeping-soa.md §3.1: the one
# module through which every writer of timesheet_entries (§1.3, W1-W7) changes
# entry state. Controllers, the import, agent destroy and the invoice
# callbacks authenticate and authorize as today, then hand it a command. The
# gateway sends the command to the owner the ownership record names (§10.1).
#
# The generation fence (§10.1): every command runs in a transaction that holds
# the ownership row FOR SHARE, and the owner is taken from that locked read.
# Raising the generation takes the row exclusively, so a handoff waits for
# every command already admitted, and a command that arrives during it waits
# and is then refused with a retryable Timekeeping::Ownership::Moving. Because
# the owner is chosen under the lock, a command can never run against a
# generation that was raised after it was read. Billing writes pass the same
# fence through Timekeeping::BillingWriteFence.
#
# The legacy owner (§10.2 step 2) runs today's model code unchanged. The
# timekeeping owner (Remote) forwards the single-entry and bulk commands and
# agent detach to Timekeeping's entry API; the commands it does not forward
# yet, and every command under the monolith owner, are refused, never written
# locally, because a local write there would be a second writer.
module Timekeeping::Gateway
  class OwnerUnavailable < StandardError; end

  # The owner refused the command. `status` and `message` are today's public
  # error JSON for it (§5.1): the controller renders { errors: message }.
  class Refused < StandardError
    attr_reader :status

    def initialize(status:, message:)
      @status = status
      super(message)
    end
  end

  # The owner refused the command because an entry it names is locked
  # against the caller (A3, A4, A9). A writer with its own locked answer
  # today, such as W2 bulk, renders that answer for it.
  class Locked < Refused; end

  # Entry commands (W1 web and mobile, W3 CLI and so W3a MCP, W4 agent).
  # `writer` names the writer for the caller's claims (§6.1): "web",
  # "mobile", "cli", "mcp" or "agent". Each answers the entry as written.
  CreateEntry = Data.define(:project, :user, :attributes, :writer)
  UpdateEntry = Data.define(:entry, :project, :attributes, :writer)
  DiscardEntry = Data.define(:entry, :writer)

  # W2 bulk move and bulk delete. `entries` is the caller's relation, already
  # scoped by policy; `company` is the tenant the command runs in (§6.3).
  # BulkMove answers the entries it moved or skipped, for rendering (A9: a
  # skipped entry is answered, never refused); BulkDiscard answers what it
  # discarded.
  BulkMove = Data.define(:entries, :project)
  BulkDiscard = Data.define(:entries, :company)

  # W5 Harvest import, one row. `billed` rows are created unbilled and then
  # marked billed, as today (§1.3).
  ImportEntry = Data.define(:company, :attributes, :billed)

  # W6 agent destroy: replaces `dependent: :nullify` on Agent. It runs
  # before the agent row is deleted, so the destroy completes only once the
  # owner has detached the agent's entries (§3.4).
  DetachAgent = Data.define(:agent)

  # W7 the invoice callbacks, until the invoice boundary replaces them (§7).
  SetLocked = Data.define(:entries, :locked)
  MarkBilled = Data.define(:entries)

  OWNERS = { "legacy" => Timekeeping::Gateway::Legacy, "timekeeping" => Timekeeping::Gateway::Remote }.freeze

  COMMAND_KEY = :timekeeping_gateway_command
  private_constant :COMMAND_KEY

  def self.call(command)
    Timekeeping::Ownership.transaction do
      ownership = Timekeeping::Ownership.admit!
      owner = owner_for(ownership, command)
      within(command) { owner.call(command, ownership) }
    end
  end

  # The owner that runs a command under the admitted ownership record, or the
  # refusal of an owner, or of a command, not built yet. Admission closed was
  # refused first, by Ownership.admit!.
  def self.owner_for(ownership, command)
    owner = OWNERS[ownership.owner]
    return owner if owner&.handles?(command)

    raise OwnerUnavailable,
      "Timekeeping gateway: owner #{ownership.owner} is not available yet, #{command.class.name.demodulize} refused"
  end
  private_class_method :owner_for

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
