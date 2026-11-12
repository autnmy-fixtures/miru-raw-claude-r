# frozen_string_literal: true

# Timekeeping's reservations (docs/architecture/timekeeping-soa.md §7.1): the
# same rows, constraints and indexes as the prepared application's
# timekeeping_reservations, so a checkpoint carries a reservation either way
# unchanged (§10.5 step 4). The entry is in this database, so it has a
# foreign key here; the invoice is not, so its id is stable and has none.
class CreateReservations < ActiveRecord::Migration[8.1]
  def change
    create_table :reservations do |t|
      t.references :entry, null: false, foreign_key: true, index: false
      t.bigint :invoice_id, null: false
      t.bigint :company_id, null: false
      t.uuid :operation_id
      t.string :state, null: false
      t.string :disposition, null: false
      t.boolean :edit_lock, null: false
      t.timestamps

      t.index :invoice_id
      t.index :entry_id, unique: true, where: "disposition = 'active'", name: "index_reservations_one_live_per_entry"
      t.index [:entry_id, :invoice_id], unique: true, where: "state = 'committed'", name: "index_reservations_committed_identity"

      t.check_constraint "state IN ('provisional', 'committed')", name: "reservations_state"
      t.check_constraint "disposition IN ('active', 'retained')", name: "reservations_disposition"
      t.check_constraint "(state = 'provisional') = (operation_id IS NOT NULL)", name: "reservations_operation_iff_provisional"
      t.check_constraint "state = 'committed' OR disposition = 'active'", name: "reservations_provisional_active"
    end
  end
end
