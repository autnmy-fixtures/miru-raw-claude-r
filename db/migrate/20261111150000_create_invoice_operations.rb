# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §9.1: the invoice operation intent
# ledger. One row per invoice operation that changes a reservation set: its
# durable outcome, and whether that outcome has been delivered to the owner
# as commit or abort.
#
# No foreign key to invoices: an intent outlives the invoice a hard delete
# removes (§9.1, §7.3).
class CreateInvoiceOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :invoice_operations do |t|
      t.uuid :operation_id, null: false
      t.bigint :company_id, null: false
      t.bigint :invoice_id, null: false
      t.string :kind, null: false
      t.bigint :entry_ids, array: true, null: false, default: []
      t.string :state, null: false, default: "pending"
      t.bigint :generation, null: false
      t.datetime :delivered_at
      t.timestamps

      t.index :operation_id, unique: true
      # §9.1: writing the pending intent is the per-invoice serialization lock.
      t.index :invoice_id, unique: true, where: "state = 'pending'", name: "index_invoice_operations_one_pending_per_invoice"
      # What the invoice operation worker delivers: an outcome not yet delivered.
      t.index :created_at, where: "state <> 'pending' AND delivered_at IS NULL", name: "index_invoice_operations_undelivered"
      t.check_constraint "state IN ('pending', 'succeeded', 'failed')", name: "invoice_operations_state"
      t.check_constraint "kind IN ('save', 'discard', 'destroy')", name: "invoice_operations_kind"
      t.check_constraint "generation >= 0", name: "invoice_operations_generation_non_negative"
      # A pending intent has no outcome, so there is nothing to deliver yet.
      t.check_constraint "state <> 'pending' OR delivered_at IS NULL", name: "invoice_operations_pending_undelivered"
    end
  end
end
