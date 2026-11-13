# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_13_020000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "entries", force: :cascade do |t|
    t.bigint "agent_id"
    t.string "bill_status", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.float "duration", null: false
    t.string "external_run_id"
    t.string "external_session_id"
    t.text "note", default: ""
    t.bigint "project_id", null: false
    t.jsonb "proof_metadata", default: {}, null: false
    t.text "proof_url"
    t.string "review_status", default: "not_required", null: false
    t.string "source", default: "manual", null: false
    t.jsonb "source_metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "version", default: 1, null: false
    t.date "work_date", null: false
    t.index ["agent_id"], name: "index_entries_on_agent_id"
    t.index ["company_id", "project_id", "work_date"], name: "index_entries_on_company_id_and_project_id_and_work_date"
    t.index ["company_id", "user_id", "work_date"], name: "index_entries_on_company_id_and_user_id_and_work_date"
    t.check_constraint "bill_status::text = ANY (ARRAY['non_billable'::character varying, 'unbilled'::character varying, 'billed'::character varying]::text[])", name: "entries_bill_status"
    t.check_constraint "review_status::text = ANY (ARRAY['not_required'::character varying, 'pending_review'::character varying, 'approved'::character varying, 'rejected'::character varying]::text[])", name: "entries_review_status"
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying, 'cli'::character varying, 'mcp'::character varying, 'automation'::character varying, 'import'::character varying]::text[])", name: "entries_source"
    t.check_constraint "version >= 1", name: "entries_version_positive"
  end

  create_table "entry_audits", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor", null: false
    t.bigint "agent_id"
    t.jsonb "audited_changes", null: false
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.bigint "entry_id", null: false
    t.string "request_id", null: false
    t.bigint "version", null: false
    t.string "writer", null: false
    t.index ["company_id"], name: "index_entry_audits_on_company_id"
    t.index ["entry_id"], name: "index_entry_audits_on_entry_id"
    t.check_constraint "action::text = ANY (ARRAY['create'::character varying, 'update'::character varying]::text[])", name: "entry_audits_action"
  end

  create_table "idempotency_receipts", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "request_digest", null: false
    t.jsonb "response", null: false
    t.integer "status", null: false
    t.index ["company_id", "key"], name: "index_idempotency_receipts_on_company_id_and_key", unique: true
  end

  create_table "outbox_snapshots", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.bigint "entry_id", null: false
    t.string "request_id", null: false
    t.jsonb "snapshot", null: false
    t.bigint "version", null: false
    t.index ["entry_id", "version"], name: "index_outbox_snapshots_on_entry_id_and_version", unique: true
    t.index ["id"], name: "index_outbox_snapshots_undelivered", where: "(delivered_at IS NULL)"
  end

  create_table "ownerships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "generation", default: 0, null: false
    t.string "owner", default: "legacy", null: false
    t.string "state", default: "open", null: false
    t.datetime "updated_at", null: false
    t.check_constraint "generation >= 0", name: "ownerships_generation_non_negative"
    t.check_constraint "id = 1", name: "ownerships_singleton"
    t.check_constraint "owner::text = ANY (ARRAY['legacy'::character varying, 'timekeeping'::character varying, 'monolith'::character varying]::text[])", name: "ownerships_owner"
    t.check_constraint "state::text = ANY (ARRAY['open'::character varying, 'closed'::character varying, 'frozen'::character varying]::text[])", name: "ownerships_state"
  end

  create_table "reservation_operations", force: :cascade do |t|
    t.bigint "company_id"
    t.datetime "created_at", null: false
    t.bigint "entry_ids", default: [], null: false, array: true
    t.bigint "invoice_id", null: false
    t.string "invoice_state"
    t.string "kind"
    t.uuid "operation_id", null: false
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id", "operation_id"], name: "index_reservation_operations_identity", unique: true
    t.index ["invoice_id"], name: "index_reservation_operations_one_unresolved", unique: true, where: "((state)::text = 'prepared'::text)"
    t.check_constraint "invoice_state::text = ANY (ARRAY['draft'::character varying, 'non_draft'::character varying]::text[])", name: "reservation_operations_invoice_state"
    t.check_constraint "kind::text = ANY (ARRAY['save'::character varying, 'discard'::character varying, 'destroy'::character varying]::text[])", name: "reservation_operations_kind"
    t.check_constraint "state::text = 'aborted'::text OR company_id IS NOT NULL AND kind IS NOT NULL AND invoice_state IS NOT NULL", name: "reservation_operations_prepared_described"
    t.check_constraint "state::text = ANY (ARRAY['prepared'::character varying, 'committed'::character varying, 'aborted'::character varying]::text[])", name: "reservation_operations_state"
  end

  create_table "reservations", force: :cascade do |t|
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "disposition", null: false
    t.boolean "edit_lock", null: false
    t.bigint "entry_id", null: false
    t.bigint "invoice_id", null: false
    t.uuid "operation_id"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id", "invoice_id"], name: "index_reservations_committed_identity", unique: true, where: "((state)::text = 'committed'::text)"
    t.index ["entry_id"], name: "index_reservations_one_live_per_entry", unique: true, where: "((disposition)::text = 'active'::text)"
    t.index ["invoice_id"], name: "index_reservations_on_invoice_id"
    t.check_constraint "(state::text = 'provisional'::text) = (operation_id IS NOT NULL)", name: "reservations_operation_iff_provisional"
    t.check_constraint "disposition::text = ANY (ARRAY['active'::character varying, 'retained'::character varying]::text[])", name: "reservations_disposition"
    t.check_constraint "state::text = 'committed'::text OR disposition::text = 'active'::text", name: "reservations_provisional_active"
    t.check_constraint "state::text = ANY (ARRAY['provisional'::character varying, 'committed'::character varying]::text[])", name: "reservations_state"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  add_foreign_key "entry_audits", "entries"
  add_foreign_key "outbox_snapshots", "entries"
  add_foreign_key "reservations", "entries"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
