# frozen_string_literal: true

# Timekeeping's entry audit rows (docs/architecture/timekeeping-soa.md §3.2,
# §3.4): one per entry change, written in the change's own transaction, as
# the existing application's `audited` writes one per TimesheetEntry change
# today. They travel in the checkpoint (§10.5 step 4).
#
# `action` takes audited's names: a discard or an agent detach is an update.
# `actor` is the token's subject (§6.1), `user:<id>` or `system`; `version`
# is the entry version the change produced.
class CreateEntryAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :entry_audits do |t|
      t.references :entry, null: false, foreign_key: true
      t.bigint :company_id, null: false
      t.string :action, null: false
      t.jsonb :audited_changes, null: false
      t.bigint :version, null: false
      t.string :actor, null: false
      t.bigint :agent_id
      t.string :writer, null: false
      t.string :request_id, null: false
      t.datetime :created_at, null: false

      t.index :company_id

      t.check_constraint "action IN ('create', 'update')", name: "entry_audits_action"
    end
  end
end
