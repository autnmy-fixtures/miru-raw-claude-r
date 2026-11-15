# frozen_string_literal: true

# What the prepared application's own tables hold, in the form a handoff's
# checkpoint carries it (docs/architecture/timekeeping-soa.md §10.5 step 4):
# every entry as the full entry (common.json#/$defs/entry), every reservation
# as a TimekeepingReservations::Reservation value, and the audit rows,
# terminal operation receipts and idempotency receipts in the forms
# handoff_api.json defines.
#
# Two readers, one rendering, so they cannot drift apart: the re-cutover's
# checkpoint takes these rows out of the prepared application
# (Timekeeping::LocalCheckpoint), and the rollback's reconcile compares them
# with the checkpoint it loaded (Timekeeping::RollbackReconcile).
#
# Values are read as stored (§8 item 1): the float duration, timestamps in
# UTC to the microsecond, JSON columns as stored. No guard and no write: each
# caller holds the ownership record its own step needs.
module Timekeeping::PreparedRows
  # One receipt part: its table, the contract definition that names its
  # columns, and the columns that order it. Audit rows keep their ids, the
  # only identity they have; a receipt is identified by its own key, so its
  # surrogate id stays behind.
  Part = Data.define(:model, :columns, :order) do
    def self.of(model, definition, order)
      columns = Timekeeping::Contracts.document(:handoff_api).dig("$defs", definition, "properties").keys
      new(model:, columns: columns.freeze, order: order.freeze)
    end

    # Every row, in order, in contract form: timestamps in UTC to the
    # microsecond, every other column as stored.
    def held
      model.order(*order).pluck(*columns).map do |values|
        columns.zip(values).to_h { |column, value| [column, column.end_with?("_at") ? value&.utc&.iso8601(6) : value] }
      end
    end
  end

  # By the checkpoint member each part is carried as.
  PARTS = {
    entry_audits: Part.of(Timekeeping::EntryAudit, "entry_audit", %i[id]),
    reservation_operations: Part.of(Timekeeping::ReservationOperation, "operation_receipt", %i[invoice_id operation_id]),
    idempotency_receipts: Part.of(Timekeeping::IdempotencyReceipt, "idempotency_receipt", %i[company_id key])
  }.freeze

  # Every entry, discarded ones included, in id order, at the version the
  # prepared application holds, with the `locked` its reservations derive
  # (§7.1).
  def self.entries = Timekeeping::Entry.includes(:reservations).order(:id).map(&:to_contract)

  # Every reservation, by entry.
  def self.reservations = Timekeeping::Reservation.order(:entry_id, :id).map(&:to_value)

  # The rows of the part carried as `member`.
  def self.held(member) = PARTS.fetch(member).held
end
