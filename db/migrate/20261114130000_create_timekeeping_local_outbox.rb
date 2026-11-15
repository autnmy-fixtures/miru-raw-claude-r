# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §3.2, §5.4, §10.1: the prepared
# application's outbox, added inactive beside its entry tables
# (20261114120000). After a rollback the `monolith` owner writes its own
# entries, and timesheet_entries stays a projection with one writer, the
# projection consumer. Every entry change of that owner writes its entry
# snapshot here in the change's own transaction, and the local relay
# (Timekeeping::LocalRelay) drains it into the consumer, as Timekeeping's
# relay drains Timekeeping's outbox.
#
# It is Timekeeping's outbox_snapshots, column for column
# (services/timekeeping/db/migrate): the id is the outbox position the relay
# delivers in and a handoff away from this owner freezes at (§10.5 step 3),
# `snapshot` is exactly the contract's entry_snapshot, and `request_id` keeps
# X-Request-Id beside it (§11.3). Each row is marked delivered on its own,
# because changes commit in any order, so a single delivered position could
# pass over a row that became visible late. The partial index is the relay's
# queue.
class CreateTimekeepingLocalOutbox < ActiveRecord::Migration[8.1]
  def change
    create_table :timekeeping_outbox_snapshots do |t|
      t.references :entry, null: false, foreign_key: { to_table: :timekeeping_entries }, index: false
      t.bigint :company_id, null: false
      t.bigint :version, null: false
      t.jsonb :snapshot, null: false
      t.string :request_id, null: false
      t.datetime :delivered_at
      t.datetime :created_at, null: false

      t.index [:entry_id, :version], unique: true
      t.index :id, where: "delivered_at IS NULL", name: "index_timekeeping_outbox_snapshots_undelivered"
    end
  end
end
