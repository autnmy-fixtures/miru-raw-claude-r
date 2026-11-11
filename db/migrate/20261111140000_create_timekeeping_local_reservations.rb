# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §10.2 step 4: the prepared
# application's own reservation table, added inactive. After a rollback the
# existing application enforces the corrected rule (F1, F2, F3) through the
# shared decision table on these rows, never through the old `locked`
# callbacks (§10.5).
#
# Neither table has a foreign key. A reservation outlives a destroyed
# non-draft invoice and carries its owner itself (§7.1, §7.3), and
# timesheet_entries is a projection once a handoff has run (§10.1).
class CreateTimekeepingLocalReservations < ActiveRecord::Migration[8.1]
  def change
    # One row per (invoice, operation): the operation as prepare received it,
    # and its terminal receipt once committed or aborted (§5.3). An abort of
    # an operation never prepared leaves a receipt that describes nothing else.
    create_table :timekeeping_reservation_operations do |t|
      t.bigint :invoice_id, null: false
      t.uuid :operation_id, null: false
      t.bigint :company_id
      t.string :kind
      t.string :invoice_state
      t.bigint :entry_ids, array: true, null: false, default: []
      t.string :state, null: false
      t.timestamps

      t.index [:invoice_id, :operation_id], unique: true, name: "index_timekeeping_reservation_operations_identity"
      # §5.3: an invoice has at most one unresolved operation.
      t.index :invoice_id, unique: true, where: "state = 'prepared'", name: "index_timekeeping_reservation_operations_one_unresolved"
      t.check_constraint "state IN ('prepared', 'committed', 'aborted')", name: "timekeeping_reservation_operations_state"
      t.check_constraint "kind IN ('save', 'discard', 'destroy')", name: "timekeeping_reservation_operations_kind"
      t.check_constraint "invoice_state IN ('draft', 'non_draft')", name: "timekeeping_reservation_operations_invoice_state"
      t.check_constraint "state = 'aborted' OR (company_id IS NOT NULL AND kind IS NOT NULL AND invoice_state IS NOT NULL)",
        name: "timekeeping_reservation_operations_prepared_described"
    end

    # §7.1: identified by (entry, invoice) once committed; a provisional one
    # belongs to the operation that prepared it.
    create_table :timekeeping_reservations do |t|
      t.bigint :entry_id, null: false
      t.bigint :invoice_id, null: false
      t.bigint :company_id, null: false
      t.uuid :operation_id
      t.string :state, null: false
      t.string :disposition, null: false
      t.boolean :edit_lock, null: false
      t.timestamps

      # F1: at most one reservation by a kept invoice per entry. Provisional
      # ones are always `active`, so this covers "or a provisional one" too.
      # A retained reservation does not count.
      t.index :entry_id, unique: true, where: "disposition = 'active'", name: "index_timekeeping_reservations_one_live_per_entry"
      t.index [:entry_id, :invoice_id], unique: true, where: "state = 'committed'", name: "index_timekeeping_reservations_committed_identity"
      t.index :invoice_id
      t.check_constraint "state IN ('provisional', 'committed')", name: "timekeeping_reservations_state"
      t.check_constraint "disposition IN ('active', 'retained')", name: "timekeeping_reservations_disposition"
      t.check_constraint "(state = 'provisional') = (operation_id IS NOT NULL)", name: "timekeeping_reservations_operation_iff_provisional"
      t.check_constraint "state = 'committed' OR disposition = 'active'", name: "timekeeping_reservations_provisional_active"
    end
  end
end
