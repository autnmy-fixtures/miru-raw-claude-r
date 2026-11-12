# frozen_string_literal: true

# Timekeeping's entries (docs/architecture/timekeeping-soa.md §3.2): every
# column of the existing application's timesheet_entries, the same ids, plus
# the tenant every query is scoped by (§6.3) and the version the projection
# orders snapshots by (§3.2). `locked` is not a column: it is derived from
# the entry's reservations (§7.1).
#
# The enums are stored by name, the names the contracts carry
# (common.json), so a value the contracts do not list cannot be stored.
class CreateEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :entries do |t|
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

      t.index [:company_id, :user_id, :work_date]
      t.index [:company_id, :project_id, :work_date]
      t.index :agent_id

      t.check_constraint "version >= 1", name: "entries_version_positive"
      t.check_constraint "bill_status IN ('non_billable', 'unbilled', 'billed')", name: "entries_bill_status"
      t.check_constraint "review_status IN ('not_required', 'pending_review', 'approved', 'rejected')", name: "entries_review_status"
      t.check_constraint "source IN ('manual', 'cli', 'mcp', 'automation', 'import')", name: "entries_source"
    end
  end
end
