# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §3.1, §3.2, §10.5: the prepared
# application's own entry tables, added inactive beside its reservation table
# (20261111140000). After a rollback the `monolith` owner writes these, its
# authoritative tables, and timesheet_entries stays a projection written only
# by the projection consumer (§10.1). They hold what a rollback's checkpoint
# carries (§10.5 step 4): every entry, its audit rows and the entry API's
# idempotency receipts. Reservations and operation receipts already have
# their tables.
#
# Each table is the one Timekeeping keeps (services/timekeeping/db/migrate),
# so a checkpoint moves between the two owners column for column: the same
# ids, `company_id` (§6.3), `version` (§3.2), and enums stored by the names the
# contracts carry. `locked` is not a column: it is derived from the entry's
# reservations by the shared rule (§7.1).
#
# The id sequence is this table's own. At rollback it is set above the
# highest Timekeeping id (§10.3); nothing allocates from it before then.
class CreateTimekeepingLocalEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :timekeeping_entries do |t|
      t.bigint :company_id, null: false
      t.bigint :project_id, null: false
      t.bigint :user_id, null: false
      t.bigint :agent_id
      t.float :duration, null: false
      t.date :work_date, null: false
      t.text :note, default: ""
      t.string :bill_status, null: false
      t.string :review_status, null: false, default: "not_required"
      t.string :source, null: false, default: "manual"
      t.jsonb :source_metadata, null: false, default: {}
      t.text :proof_url
      t.jsonb :proof_metadata, null: false, default: {}
      t.string :external_run_id
      t.string :external_session_id
      t.datetime :discarded_at
      t.bigint :version, null: false, default: 1
      t.timestamps

      t.index [:company_id, :user_id, :work_date], name: "index_timekeeping_entries_on_company_user_work_date"
      t.index [:company_id, :project_id, :work_date], name: "index_timekeeping_entries_on_company_project_work_date"
      t.index :agent_id

      t.check_constraint "version >= 1", name: "timekeeping_entries_version_positive"
      t.check_constraint "bill_status IN ('non_billable', 'unbilled', 'billed')", name: "timekeeping_entries_bill_status"
      t.check_constraint "review_status IN ('not_required', 'pending_review', 'approved', 'rejected')",
        name: "timekeeping_entries_review_status"
      t.check_constraint "source IN ('manual', 'cli', 'mcp', 'automation', 'import')", name: "timekeeping_entries_source"
    end

    # One per entry change, in the change's own transaction (§3.4). `action`
    # takes audited's names; `actor` is `user:<id>` or `system` (§6.1).
    create_table :timekeeping_entry_audits do |t|
      t.references :entry, null: false, foreign_key: { to_table: :timekeeping_entries }
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

      t.check_constraint "action IN ('create', 'update')", name: "timekeeping_entry_audits_action"
    end

    # `(key, request digest, response)` per tenant (§9.4): a client retry
    # after a handoff returns its stored result. The same key from another
    # company is another receipt (§6.3).
    create_table :timekeeping_idempotency_receipts do |t|
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
