# frozen_string_literal: true

require "rails_helper"

# The three contracts of docs/architecture/timekeeping-soa.md §5 and §12.3:
# well-formed, complete against the table they carry, and accepting the
# design's own examples.
RSpec.describe "Timekeeping contract schemas" do
  let(:contracts) { TimekeepingContracts }

  it "is a valid 2020-12 schema for every contract, and every operation's definitions resolve" do
    contracts::NAMES.each do |name|
      expect(JSONSchemer.valid_schema?(contracts.document(name))).to be(true), "#{name} is not a valid schema"
    end
    contracts.operations.each do |operation|
      pointers = [operation.request, operation.query, *operation.responses.values].compact
      pointers.each { |pointer| expect { contracts.valid?(operation.contract, pointer, {}) }.not_to raise_error }
    end
  end

  it "lists the routes of §5.2, §5.3 and §5.4" do
    routes = contracts.operations.map { |operation| "#{operation.verb} #{operation.path}" }

    expect(routes).to contain_exactly(
      "POST /internal/v1/entries",
      "PATCH /internal/v1/entries/{id}",
      "DELETE /internal/v1/entries/{id}",
      "POST /internal/v1/entries/bulk_move",
      "POST /internal/v1/entries/bulk_discard",
      "POST /internal/v1/imports/{import_id}/batches/{n}",
      "POST /internal/v1/agents/{agent_id}/detach",
      "GET /internal/v1/entries",
      "GET /internal/v1/entries/{id}",
      "GET /internal/v1/candidates",
      "POST /internal/v1/invoices/{invoice_id}/operations/{operation_id}/prepare",
      "POST /internal/v1/invoices/{invoice_id}/operations/{operation_id}/commit",
      "POST /internal/v1/invoices/{invoice_id}/operations/{operation_id}/abort",
      "POST /internal/v1/projection/entry_snapshots"
    )
  end

  describe "the entry the contracts carry" do
    let(:fields) { contracts.document(:common).dig("$defs", "entry_fields") }

    it "has every column of timesheet_entries but id, all required" do
      expect(fields["properties"].keys).to match_array(TimesheetEntry.column_names - ["id"])
      expect(fields["required"]).to match_array(fields["properties"].keys)
    end

    it "has today's enum values and sources" do
      defs = contracts.document(:common)["$defs"]

      expect(defs.dig("bill_status", "enum")).to eq(TimesheetEntry.bill_statuses.keys)
      expect(defs.dig("review_status", "enum")).to eq(TimesheetEntry.review_statuses.keys)
      expect(defs.dig("source", "enum")).to eq(TimesheetEntry::SOURCES)
    end

    it "matches what the existing application holds for an entry today" do
      entry = create(:timesheet_entry, duration: 90.7, source_metadata: { "tool" => "cli" })
      snapshot = JSON.parse({
        "type" => "timekeeping.entry_snapshot.v1", "entry_id" => entry.id, "version" => 1, "company_id" => entry.company.id,
        "data" => entry.attributes.except("id")
      }.to_json)

      expect(contracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", snapshot).dig("data", "duration")).to eq(90.7)
    end
  end

  # §5.1: duration is the stored float in shortest round-trip form.
  it "round-trips a float duration through JSON exactly" do
    [90.7, 0.1, 479.99999, 19.0, 6_000_000.0, 1.0 / 3].each do |duration|
      wire = JSON.generate({ "duration" => duration })

      expect(JSON.parse(wire)["duration"]).to eq(duration)
      expect(contracts.valid?(:entry_api, "common.json#/$defs/duration", JSON.parse(wire)["duration"])).to be(true)
    end
  end

  describe "the design's examples" do
    let(:operation_id) { "6f1c1c3e-2a51-4d0e-9a8e-4b5d1c2e7f10" }

    it "accepts the prepare request and every prepare answer of §5.3" do
      expect(contracts.valid?(:reservation_api, "#/$defs/prepare_request", {
        "company_id" => 42, "generation" => 3, "kind" => "save", "invoice_state" => "draft",
        "entry_ids" => [101, 102, 205], "resolves" => nil
      })).to be(true)
      expect(contracts.valid?(:reservation_api, "#/$defs/prepare_request", {
        "company_id" => 42, "generation" => 3, "kind" => "discard", "invoice_state" => "draft",
        "entry_ids" => [], "resolves" => { "operation_id" => operation_id, "outcome" => "aborted" }
      })).to be(true)
      expect(contracts.valid?(:reservation_api, "#/$defs/prepare_response", {
        "status" => "prepared",
        "entries" => [{ "id" => 101, "company_id" => 42, "project_id" => 7, "user_id" => 3, "duration" => 90.7, "work_date" => "2026-11-02", "version" => 14 }]
      })).to be(true)
      expect(contracts.valid?(:reservation_api, "#/$defs/prepare_response", { "status" => "committed" })).to be(true)
      expect(contracts.valid?(:reservation_api, "common.json#/$defs/problem", {
        "type" => contracts.problem_type("reservation-refused"), "title" => "Reservation refused", "status" => 409,
        "retryable" => false, "refused" => [{ "entry_id" => 205, "reason" => "on_other_invoice" }]
      })).to be(true)
      expect(contracts.valid?(:reservation_api, "common.json#/$defs/problem", {
        "type" => contracts.problem_type("operation-unresolved"), "title" => "Operation unresolved", "status" => 409, "retryable" => true
      })).to be(true)
    end

    it "accepts the entry snapshot of §5.4" do
      expect(contracts.valid?(:entry_snapshot, "#/$defs/entry_snapshot", {
        "type" => "timekeeping.entry_snapshot.v1", "entry_id" => 101, "version" => 15, "company_id" => 42,
        "data" => {
          "project_id" => 7, "user_id" => 3, "agent_id" => nil, "duration" => 90.7, "work_date" => "2026-11-02",
          "note" => "…", "bill_status" => "unbilled", "review_status" => "not_required", "locked" => true,
          "source" => "manual", "source_metadata" => {}, "proof_url" => nil, "proof_metadata" => {},
          "external_run_id" => nil, "external_session_id" => nil, "discarded_at" => nil,
          "created_at" => "2026-11-02T09:00:00Z", "updated_at" => "2026-11-02T09:00:00Z"
        }
      })).to be(true)
    end

    it "accepts the user token claims of §6.1 with their audience and TTL" do
      expect(contracts.valid?(:entry_api, "#/$defs/token_claims", {
        "sub" => "user:7", "aud" => "timekeeping", "iat" => 1_700_000_000, "exp" => 1_700_000_060,
        "company_id" => 42, "role" => "employee", "timesheet_edit_days" => 7,
        "actor" => { "type" => "user", "agent_id" => nil }, "writer" => "web",
        "project" => { "id" => 9, "company_id" => 42, "kept" => true, "billable" => true }, "request_id" => "req-1"
      })).to be(true)
    end
  end

  describe "what the schemas refuse" do
    it "refuses an unknown snapshot field, an unknown problem type and an unknown refusal reason" do
      snapshot = TimekeepingContracts::FakeRelay.new.snapshot(entry_id: 1, version: 1, company_id: 1, project_id: 1, user_id: 1, duration: 1.0, work_date: "2026-11-02")

      expect(contracts.valid?(:entry_snapshot, "#/$defs/entry_snapshot", snapshot.deep_merge("data" => { "invoice_id" => 3 }))).to be(false)
      expect(contracts.valid?(:entry_api, "common.json#/$defs/problem", { "type" => "about:blank", "title" => "x", "status" => 400, "retryable" => false })).to be(false)
      expect(contracts.valid?(:entry_api, "common.json#/$defs/problem", {
        "type" => contracts.problem_type("reservation-refused"), "title" => "x", "status" => 409, "retryable" => false,
        "refused" => [{ "entry_id" => 1, "reason" => "locked" }]
      })).to be(false)
    end

    it "refuses an import batch over 500 rows and a create without its required columns" do
      row = { "project_id" => 1, "user_id" => 1, "duration" => 60.0, "work_date" => "2026-11-02" }

      expect(contracts.valid?(:entry_api, "#/$defs/import_batch_request", { "rows" => [row] * 500 })).to be(true)
      expect(contracts.valid?(:entry_api, "#/$defs/import_batch_request", { "rows" => [row] * 501 })).to be(false)
      expect(contracts.valid?(:entry_api, "#/$defs/entry_create_request", { "entry" => row.except("work_date") })).to be(false)
    end

    it "refuses a writer setting agent_id, company_id or locked" do
      %w[agent_id company_id locked].each do |column|
        expect(contracts.valid?(:entry_api, "#/$defs/entry_update_request", { "entry" => { column => 1 } })).to be(false), column
      end
    end
  end
end
