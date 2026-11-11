# frozen_string_literal: true

# The invoice operation intent ledger of docs/architecture/timekeeping-soa.md
# §9.1: one row per invoice operation (save, discard, destroy) that changes a
# reservation set. It records the operation's durable outcome, and it is its
# own outbox: an outcome with no `delivered_at` is what the invoice operation
# worker delivers to the owner, `succeeded` as commit and `failed` as abort.
# Recording the outcome and queuing its delivery are one row change, so they
# cannot be split (§9.3).
#
# The save order of §9.2, from the ledger's side:
#
#   1. .open! writes the pending intent in its own committed transaction,
#      before prepare. The partial unique index on pending intents makes that
#      write the per-invoice serialization lock. It works for creation (the
#      invoice id is taken from invoices_id_seq first) and for deletion,
#      where no invoice row is left to lock.
#   3. #succeed! runs inside the invoice transaction. It locks the intent,
#      checks it is still pending, and records success with the invoice
#      change, so the two commit or roll back together. #reconcile answers a
#      prepare that returned an earlier terminal receipt instead.
#   4. #record_failure! is every failure path and recovery: pending becomes
#      failed only if nothing recorded success first. Taking the row FOR
#      UPDATE waits for a step-3 transaction still in progress.
#
# A missing response or elapsed time never releases a reservation on its own.
# Time only decides when .recover! looks.
#
# The ledger's own transitions pass no billing-write fence: during a handoff,
# settle (§10.5 step 2) resolves every pending intent from its durable
# outcome, and delivery must still run. Opening an intent is admitted like
# any other write, because it starts a reservation change.
class Timekeeping::InvoiceOperation < ApplicationRecord
  # Retryable: another operation of this invoice is still pending (§9.1).
  # Recovery resolves it; the client retries.
  class Busy < StandardError; end

  # Retryable: the intent was resolved, by recovery or settle, before the
  # invoice change could record success (§9.2 step 3). The invoice
  # transaction must roll back.
  class NoLongerPending < StandardError; end

  # A caller broke the save order: the intent was opened inside another
  # transaction, so it would not be durable before prepare, or success was
  # recorded outside the invoice transaction, so it would not commit with it.
  class TransactionOrder < StandardError; end

  self.table_name = "invoice_operations"

  ONE_PENDING_INDEX = "index_invoice_operations_one_pending_per_invoice"

  enum :state, { pending: "pending", succeeded: "succeeded", failed: "failed" }, prefix: true

  # What the invoice operation worker delivers for each outcome (§9.1).
  DELIVERIES = { "succeeded" => :commit, "failed" => :abort }.freeze

  # The terminal receipt the owner stores for each outcome (§5.3).
  RECEIPTS = { "succeeded" => "committed", "failed" => "aborted" }.freeze

  # §9.2 step 3: prepare answered 200 with this operation's terminal receipt,
  # so the change is never re-run. [receipt, intent] => what the save does:
  # only an outcome and its own receipt agree. Every other pair, an intent
  # still pending included, is :unreconciled: a retryable reconciliation
  # error that changes nothing.
  RECONCILIATIONS = RECEIPTS.to_h { |state, receipt| [[receipt, state], state.to_sym] }.freeze

  scope :undelivered, -> { where(state: DELIVERIES.keys, delivered_at: nil) }
  scope :pending_before, ->(time) { state_pending.where(created_at: ...time) }

  # §9.2 step 1. Admitted under the ownership fence (§10.1), so a handoff
  # waits for it and refuses it once admission closes; the intent carries the
  # generation its prepare, commit and abort are sent under.
  def self.open!(invoice_id:, company_id:, kind:, entry_ids: [])
    if in_application_transaction?
      raise TransactionOrder, "invoice #{invoice_id}: the operation intent must commit on its own, before prepare"
    end

    transaction(requires_new: true) do
      create!(
        operation_id: SecureRandom.uuid, invoice_id:, company_id:, kind: kind.to_s, entry_ids:,
        generation: Timekeeping::Ownership.admit!.generation
      )
    end
  rescue ActiveRecord::RecordNotUnique => error
    raise unless error.message.include?(ONE_PENDING_INDEX)

    raise Busy, "invoice #{invoice_id} has an operation still pending; retry once it is resolved"
  end

  # Recovery (§9.2): resolves every intent pending since before `time` that
  # no save has recorded success for. Answers each one's durable outcome.
  def self.recover!(before:)
    pending_before(before).order(:id).to_h { |intent| [intent.operation_id, intent.record_failure!] }
  end

  # Whether the caller is inside a transaction the application opened. A
  # test's fixture transaction is not joinable, so it does not count.
  def self.in_application_transaction?
    connection.current_transaction.joinable?
  end

  # §9.2 step 3, inside the invoice transaction, after prepare answered
  # `prepared`.
  def succeed!
    unless self.class.in_application_transaction?
      raise TransactionOrder, "operation #{operation_id}: success must be recorded inside the invoice transaction"
    end

    lock!
    raise NoLongerPending, "operation #{operation_id} was already resolved as #{state}; retry the save" unless state_pending?

    update!(state: :succeeded)
  end

  # §9.2 step 4 and recovery: records `failed` only if the intent is still
  # pending, which queues abort in the same row change. Answers the durable
  # outcome: "failed", or "succeeded" when the save committed first and
  # commit is already queued. Idempotent.
  def record_failure!
    self.class.transaction(requires_new: true) do
      lock!
      update!(state: :failed) if state_pending?
      state
    end
  end

  # §9.2 step 3, for a prepare that returned a terminal receipt: compares it
  # with the intent as stored now.
  def reconcile(receipt)
    RECONCILIATIONS.fetch([receipt.to_s, reload.state], :unreconciled)
  end

  # The `resolves` this intent's prepare carries (§5.3): the outcome of the
  # latest earlier operation of its invoice not yet delivered, which the owner
  # may still hold unresolved, or nil. An undelivered outcome is never
  # pending: .open! admits one pending intent per invoice, and this one is it.
  def resolves
    earlier = self.class.undelivered.where(invoice_id:, id: ...id).order(:id).last
    earlier && { "operation_id" => earlier.operation_id, "outcome" => RECEIPTS.fetch(earlier.state) }
  end

  # The call the worker sends for this outcome. A pending intent has none.
  def delivery
    DELIVERIES.fetch(state) { raise ArgumentError, "operation #{operation_id} is pending: nothing to deliver" }
  end

  # The owner answered the delivery. Idempotent.
  def mark_delivered!
    delivery # refuses a pending intent
    update!(delivered_at: Time.current) unless delivered_at
  end
end
