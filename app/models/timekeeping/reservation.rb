# frozen_string_literal: true

# One row of the prepared application's reservation table
# (docs/architecture/timekeeping-soa.md §7.1, §10.2 step 4). The rule lives in
# the shared decision table; this model only maps a row to and from its
# TimekeepingReservations::Reservation value. Timekeeping::LocalReservations
# is its only writer.
class Timekeeping::Reservation < ApplicationRecord
  self.table_name = "timekeeping_reservations"

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
