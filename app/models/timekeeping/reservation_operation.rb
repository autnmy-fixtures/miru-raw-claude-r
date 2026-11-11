# frozen_string_literal: true

# One reservation operation of the prepared application, by (invoice,
# operation) (docs/architecture/timekeeping-soa.md §5.3): the operation as
# prepare received it while it is unresolved, and its terminal receipt once
# it is committed or aborted.
class Timekeeping::ReservationOperation < ApplicationRecord
  self.table_name = "timekeeping_reservation_operations"

  enum :state, { prepared: "prepared", committed: "committed", aborted: "aborted" }, prefix: true

  def self.row_for(operation)
    operation.to_h.merge(kind: operation.kind.to_s, invoice_state: operation.invoice_state.to_s)
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
