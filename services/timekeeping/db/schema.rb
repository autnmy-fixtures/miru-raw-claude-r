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

ActiveRecord::Schema[8.1].define(version: 2026_11_11_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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
end
