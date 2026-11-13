# frozen_string_literal: true

# One row per (invoice, operation) of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3): the operation as prepare
# received it while it is unresolved, and its terminal receipt once it is
# committed or aborted. The same columns, constraints and indexes as the
# prepared application's timekeeping_reservation_operations, so a checkpoint
# carries the receipts either way unchanged (§10.5 step 4).
#
# The invoice is not in this database, so its id is stable and has no
# foreign key; the row outlives a destroyed invoice (§7.3).
class CreateReservationOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservation_operations do |t|
      t.bigint :invoice_id, null: false
      t.uuid :operation_id, null: false
      t.bigint :company_id
      t.string :kind
      t.string :invoice_state
      t.bigint :entry_ids, array: true, null: false, default: []
      t.string :state, null: false
      t.timestamps

      t.index [:invoice_id, :operation_id], unique: true, name: "index_reservation_operations_identity"
      # §5.3: an invoice has at most one unresolved operation.
      t.index :invoice_id, unique: true, where: "state = 'prepared'", name: "index_reservation_operations_one_unresolved"
      t.check_constraint "state IN ('prepared', 'committed', 'aborted')", name: "reservation_operations_state"
      t.check_constraint "kind IN ('save', 'discard', 'destroy')", name: "reservation_operations_kind"
      t.check_constraint "invoice_state IN ('draft', 'non_draft')", name: "reservation_operations_invoice_state"
      t.check_constraint "state = 'aborted' OR (company_id IS NOT NULL AND kind IS NOT NULL AND invoice_state IS NOT NULL)",
        name: "reservation_operations_prepared_described"
    end
  end
end
