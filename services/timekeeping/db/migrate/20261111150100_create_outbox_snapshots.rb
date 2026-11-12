# frozen_string_literal: true

# Timekeeping's outbox (docs/architecture/timekeeping-soa.md §5.4): one entry
# snapshot per entry version, written in the same transaction as the change
# that produced it. The id is the outbox position the relay delivers in and
# the handoff freezes at (§10.5 step 3).
#
# `request_id` is the request that made the change, so X-Request-Id travels
# with the snapshot (§11.3); the snapshot itself is exactly the contract's
# entry_snapshot, which has no room for it.
class CreateOutboxSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_snapshots do |t|
      t.references :entry, null: false, foreign_key: true, index: false
      t.bigint :company_id, null: false
      t.bigint :version, null: false
      t.jsonb :snapshot, null: false
      t.string :request_id, null: false
      t.datetime :created_at, null: false

      t.index [:entry_id, :version], unique: true
    end
  end
end
