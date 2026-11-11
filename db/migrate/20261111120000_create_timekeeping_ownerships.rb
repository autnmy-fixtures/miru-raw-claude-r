# frozen_string_literal: true

# The ownership record of docs/architecture/timekeeping-soa.md §10.1: one row
# holding (generation, owner, state). The column defaults are the initial
# legacy state, so a database where no handoff has ever written the row reads
# exactly like one where it was written before the first handoff.
class CreateTimekeepingOwnerships < ActiveRecord::Migration[8.1]
  def change
    create_table :timekeeping_ownerships do |t|
      t.bigint :generation, null: false, default: 0
      t.string :owner, null: false, default: "legacy"
      t.string :state, null: false, default: "open"
      t.timestamps

      t.check_constraint "id = 1", name: "timekeeping_ownerships_singleton"
      t.check_constraint "generation >= 0", name: "timekeeping_ownerships_generation_non_negative"
      t.check_constraint "owner IN ('legacy', 'timekeeping', 'monolith')", name: "timekeeping_ownerships_owner"
      t.check_constraint "state IN ('open', 'closed', 'frozen')", name: "timekeeping_ownerships_state"
    end
  end
end
