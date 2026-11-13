# frozen_string_literal: true

# One of an entry's reservations by an invoice (docs/architecture/timekeeping-soa.md
# §7.1). The rule lives in the shared decision table; this model only maps a
# row to and from its TimekeepingReservations::Reservation value.
# ReservationProtocol is its only writer.
class Reservation < ApplicationRecord
  belongs_to :entry

  def self.row_for(value)
    value.to_h.merge(state: value.state.to_s, disposition: value.disposition.to_s)
  end

  def to_value
    TimekeepingReservations::Reservation.new(
      entry_id:, invoice_id:, company_id:, operation_id:,
      state: state.to_sym, disposition: disposition.to_sym, edit_lock:
    )
  end
end
