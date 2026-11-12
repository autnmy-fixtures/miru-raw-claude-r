# frozen_string_literal: true

# The entry API's idempotency receipts (docs/architecture/timekeeping-soa.md
# §9.4): `(key, request hash, response)` for every mutating call that
# succeeded, written in the call's own transaction. They travel in the
# checkpoint (§10.5 step 4), so a client retry after a handoff returns its
# stored result.
#
# A key belongs to its tenant (§6.3): the same key from another company is
# another receipt, never a replay of this one.
class CreateIdempotencyReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_receipts do |t|
      t.bigint :company_id, null: false
      t.string :key, null: false
      t.string :request_digest, null: false
      t.integer :status, null: false
      t.jsonb :response, null: false
      t.datetime :created_at, null: false

      t.index [:company_id, :key], unique: true
    end
  end
end
