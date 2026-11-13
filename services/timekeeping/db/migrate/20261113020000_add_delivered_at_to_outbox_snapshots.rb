# frozen_string_literal: true

# What the relay has delivered (docs/architecture/timekeeping-soa.md §5.4):
# each outbox row is marked once the projection consumer has made it durable.
#
# A mark per row, not one delivered position: outbox ids are taken when a
# change inserts its row, but changes commit in any order, so a row with a
# lower id can become visible after a higher one was delivered. A position
# would pass over it for good; a mark cannot. The final position the handoff
# freezes at (§10.5 step 3) is drained when no row at or below it is unmarked.
#
# The partial index is the relay's queue: only undelivered rows, by position.
class AddDeliveredAtToOutboxSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :outbox_snapshots, :delivered_at, :datetime
    add_index :outbox_snapshots, :id, where: "delivered_at IS NULL", name: "index_outbox_snapshots_undelivered"
  end
end
