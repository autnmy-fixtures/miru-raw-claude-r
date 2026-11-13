# frozen_string_literal: true

# One reservation operation, by (invoice, operation)
# (docs/architecture/timekeeping-soa.md §5.3): the operation as prepare
# received it while it is unresolved, and its terminal receipt once it is
# committed or aborted. ReservationProtocol is its only writer.
class ReservationOperation < ApplicationRecord
  enum :state, { prepared: "prepared", committed: "committed", aborted: "aborted" }, prefix: true

  def self.row_for(operation)
    operation.to_h.merge(kind: operation.kind.to_s, invoice_state: operation.invoice_state.to_s)
  end

  # Serializes every call for one invoice until the caller's transaction
  # ends: a first prepare and its retry, two operations of the invoice, and
  # recovery's abort racing a commit. The unique indexes are the backstop.
  def self.lock_invoice!(invoice_id)
    connection.execute(sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "invoice:#{invoice_id}"]))
  end

  def terminal?
    !state_prepared?
  end

  def to_operation
    TimekeepingReservations::Operation.new(
      invoice_id:, operation_id:, company_id:, entry_ids:,
      kind: kind.to_sym, invoice_state: invoice_state.to_sym
    )
  end
end
