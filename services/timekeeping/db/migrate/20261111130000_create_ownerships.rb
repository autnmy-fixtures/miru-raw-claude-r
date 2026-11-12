# frozen_string_literal: true

# Timekeeping's copy of the ownership record (docs/architecture/timekeeping-soa.md
# §10.1): "One record holds (generation, owner, state) ... A copy lives in
# each database, written by the handoff tool." The column defaults are the
# initial legacy state, as in the existing application's copy, so a database
# where no handoff has run reads like one where it was written before the
# first handoff.
class CreateOwnerships < ActiveRecord::Migration[8.1]
  def change
    create_table :ownerships do |t|
      t.bigint :generation, null: false, default: 0
      t.string :owner, null: false, default: "legacy"
      t.string :state, null: false, default: "open"
      t.timestamps

      t.check_constraint "id = 1", name: "ownerships_singleton"
      t.check_constraint "generation >= 0", name: "ownerships_generation_non_negative"
      t.check_constraint "owner IN ('legacy', 'timekeeping', 'monolith')", name: "ownerships_owner"
      t.check_constraint "state IN ('open', 'closed', 'frozen')", name: "ownerships_state"
    end
  end
end
