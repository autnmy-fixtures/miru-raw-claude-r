# frozen_string_literal: true

# One of an entry's reservations by an invoice (docs/architecture/timekeeping-soa.md
# §7.1). The rule lives in the shared decision table; this model only maps a
# row to its TimekeepingReservations::Reservation value.
class Reservation < ApplicationRecord
  belongs_to :entry

  def to_value
    TimekeepingReservations::Reservation.new(
      entry_id:, invoice_id:, company_id:, operation_id:,
      state: state.to_sym, disposition: disposition.to_sym, edit_lock:
    )
  end
end
