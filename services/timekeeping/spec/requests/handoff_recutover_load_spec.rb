# frozen_string_literal: true

require "rails_helper"

# The handoff API's re-cutover load (handoff_api.json
# load_recutover_checkpoint), provider side (§12.3): the checkpoint the
# existing application took out of the prepared application, the outgoing
# `monolith` owner (§10.2 step 6, §10.5 steps 4 and 5), carried to Timekeeping
# and loaded over what it still holds from before the rollback. RecutoverLoad
# is tested on its own (recutover_load_spec); this proves the call reaches it
# with the checkpoint exactly as carried, answers what the contract defines,
# and answers every refusal as its problem with nothing changed.
RSpec.describe "Handoff API: the re-cutover's checkpoint load" do
  def body = JSON.parse(response.body)

  let(:rollback_generation) { 5 }
  let(:generation) { 6 }
  let(:created_at) { Time.utc(2026, 11, 2, 9, 15, 30, 123_456) }
  let(:updated_at) { Time.utc(2026, 11, 3, 17, 45, 1, 654_321) }
  let(:later) { "2026-11-12T10:20:30.000007Z" }
  let(:noop_abort) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }
  let(:new_draft_operation) { "6fa459ea-ee8a-4ca4-894e-db77e160355e" }

  def ownership!(generation: self.generation, owner: "monolith", state: "frozen")
    Ownership.current.update!(generation:, owner:, state:)
  end

  def load_recutover(payload = checkpoint, carried: payload["generation"], headers: handoff_headers(generation: carried))
    post "/internal/v1/handoff/recutover/checkpoint", params: JSON.generate(payload), headers:
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status, "retryable" => false)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  # Everything Timekeeping holds, row by row, to show a refusal wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  # What Timekeeping still holds from before the rollback, on two tenants.
  # Fork & Leaf: an entry on a kept draft at version 3 with its audit row, an
  # unlocked link, and a destroyed non-draft's retained entry (§7.3). Copper
  # Kettle: an agent's entry whose metadata holds a null inside an array,
  # which Rails' parameter parsing would rewrite. A committed receipt, the
  # no-op abort (§9.3), an idempotency receipt per tenant under one key, and
  # a delivered outbox snapshot.
  before do
    on_draft = entry!(company_id: 1, id: 101, version: 3, duration: 0.1, note: "Kitchen prep", created_at:, updated_at:)
    unlocked_link = entry!(company_id: 1, id: 102, duration: 479.99999, note: nil, created_at:, updated_at:)
    retained = entry!(company_id: 1, id: 103, version: 2, bill_status: "billed", created_at:, updated_at:)
    agent_entry = entry!(
      company_id: 2, id: 230, version: 5, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "skipped" => [nil] }, proof_metadata: { "tags" => [nil, "a"] }, created_at:, updated_at:
    )

    reservation!(on_draft, invoice_id: 501)
    reservation!(unlocked_link, invoice_id: 502, edit_lock: false)
    reservation!(retained, invoice_id: 503, disposition: "retained")
    reservation!(agent_entry, invoice_id: 601)

    EntryAudit.create!(
      id: 11, entry_id: 101, company_id: 1, action: "create", version: 1, actor: "user:7", agent_id: nil, writer: "web",
      request_id: "req-11", audited_changes: { "duration" => 0.1, "note" => nil }, created_at:
    )

    ReservationOperation.create!(
      invoice_id: 501, operation_id: "0f8e2c1a-5b4d-4e3f-9a2b-1c0d9e8f7a6b", state: "committed", company_id: 1,
      kind: "save", invoice_state: "draft", entry_ids: [101], created_at:, updated_at:
    )
    ReservationOperation.create!(invoice_id: 701, operation_id: noop_abort, state: "aborted", created_at:, updated_at:)

    IdempotencyReceipt.create!(
      company_id: 1, key: "web-1", request_digest: "d1", status: 201, response: { "entry" => { "id" => 101, "duration" => 0.1 } }, created_at:
    )
    IdempotencyReceipt.create!(company_id: 2, key: "web-1", request_digest: "d2", status: 200, response: { "entry" => nil }, created_at:)

    OutboxSnapshot.create!(
      entry_id: 101, company_id: 1, version: 3, snapshot: OutboxSnapshot.of(on_draft.reload), request_id: "req-11", delivered_at: updated_at
    )
  end

  # The prepared application's checkpoint as the wire carries it: the
  # rollback's (what it loaded from Timekeeping), plus what the monolith owner
  # accepted after. 101's draft was discarded, releasing it (F2) at version 4.
  # On Copper Kettle a new entry, 240, went on a new draft, with its audit
  # row, its receipt and an idempotency receipt.
  let(:checkpoint) do
    ownership!(generation: rollback_generation, owner: "timekeeping")
    rolled_back = JSON.parse(CheckpointTake.take(generation: rollback_generation).to_h.to_json)
    ownership!

    entries = rolled_back.fetch("entries").map do |entry|
      entry["id"] == 101 ? entry.merge("version" => 4, "locked" => false, "updated_at" => later) : entry
    end
    new_entry = entries.last.merge(
      "id" => 240, "version" => 2, "agent_id" => nil, "review_status" => "not_required", "source" => "manual",
      "source_metadata" => {}, "proof_metadata" => {}, "duration" => 45.5, "created_at" => later, "updated_at" => later
    )
    receipt = rolled_back.fetch("reservation_operations").first

    rolled_back.merge(
      "generation" => generation,
      "entries" => entries + [new_entry],
      "reservations" => rolled_back.fetch("reservations").reject { |reservation| reservation["entry_id"] == 101 } + [
        { "entry_id" => 240, "invoice_id" => 602, "company_id" => 2, "operation_id" => nil, "state" => "committed",
          "disposition" => "active", "edit_lock" => true }
      ],
      "entry_audits" => rolled_back.fetch("entry_audits") + [
        rolled_back.fetch("entry_audits").first.merge("id" => 16, "entry_id" => 240, "company_id" => 2, "request_id" => "local-16", "created_at" => later)
      ],
      "reservation_operations" => (rolled_back.fetch("reservation_operations") + [
        receipt.merge("invoice_id" => 602, "operation_id" => new_draft_operation, "company_id" => 2, "entry_ids" => [240], "created_at" => later, "updated_at" => later)
      ]).sort_by { |row| row.values_at("invoice_id", "operation_id") },
      "idempotency_receipts" => rolled_back.fetch("idempotency_receipts") + [
        { "company_id" => 2, "key" => "web-2", "request_digest" => "d3", "status" => 201, "response" => { "entry" => { "id" => 240 } }, "created_at" => later }
      ]
    )
  end

  # What Timekeeping holds, in the checkpoint's form: what the rollback's take
  # would answer if the handoff were going the other way.
  def held_as_checkpoint
    JSON.parse(CheckpointTake::Checkpoint.new(generation:, **CheckpointTake.held).to_h.to_json)
  end

  describe "a frozen re-cutover" do
    it "loads the checkpoint and answers what it loaded, part by part, as the contract defines" do
      load_recutover

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq("application/json")
      expect(contract_errors("handoff_api", "#/$defs/recutover_receipt", body)).to be_empty
      expect(body).to eq(
        "entries" => 5, "reservations" => 4, "entry_audits" => 2, "reservation_operations" => 3, "idempotency_receipts" => 3
      )
    end

    it "leaves Timekeeping holding exactly the checkpoint as carried: every part, every value (§8 item 1, §13 item 3)" do
      load_recutover

      expect(held_as_checkpoint).to eq(checkpoint)
      expect(Entry.order(:id).pluck(:id, :version, :duration)).to eq(
        [[101, 4, 0.1], [102, 1, 479.99999], [103, 2, 90.7], [230, 5, 90.7], [240, 2, 45.5]]
      )
      expect(Entry.find(230)).to have_attributes(source_metadata: { "skipped" => [nil] }, proof_metadata: { "tags" => [nil, "a"] })
      expect(Entry.find(101).updated_at).to eq(Time.utc(2026, 11, 12, 10, 20, 30, 7))
      expect(Entry.includes(:reservations).order(:id).to_h { |entry| [entry.id, entry.locked?] })
        .to eq(101 => false, 102 => false, 103 => true, 230 => true, 240 => true)
      expect(IdempotencyReceipt.find_by(company_id: 2, key: "web-2").replay("d3")).to eq([201, { "entry" => { "id" => 240 } }])
    end

    it "writes no outbox snapshot, and leaves the record frozen for the reconcile and the flip" do
      before = OutboxSnapshot.order(:id).map(&:attributes)

      load_recutover

      expect(OutboxSnapshot.order(:id).map(&:attributes)).to eq(before)
      expect(Ownership.current.summary).to eq("generation 6, owner monolith, state frozen")
    end

    it "loads the same checkpoint again to the same tables and the same answer, so a resumed handoff may carry it twice" do
      load_recutover
      first = body
      after_first = held_rows

      load_recutover

      expect(response).to have_http_status(200)
      expect(body).to eq(first)
      expect(held_as_checkpoint).to eq(checkpoint)
      expect(held_rows.values_at(0, 1, 3)).to eq(after_first.values_at(0, 1, 3))
    end
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { state: "open" },
      "admission closed, settle may still be running" => { state: "closed" },
      "frozen at another generation" => { generation: 7 },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy" },
      "frozen while Timekeeping is the outgoing owner (a rollback)" => { owner: "timekeeping" }
    }.each do |name, ownership|
      it "refuses with #{name} as out-of-step, and changes nothing" do
        payload = checkpoint
        ownership!(**ownership)
        before = held_rows

        load_recutover(payload)
        expect_problem(409, "out-of-step")
        expect(body["detail"]).to match(/load expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end
  end

  it "refuses a checkpoint that does not hold together or would drop what Timekeeping holds as checkpoint-refused, listing each check, and loads nothing" do
    refused = checkpoint.merge(
      "entries" => checkpoint.fetch("entries").map do |entry|
        case entry["id"]
        when 240 then entry.merge("locked" => false)
        when 230 then entry.merge("version" => 4)
        else entry
        end
      end,
      "entry_audits" => checkpoint.fetch("entry_audits").map { |audit| audit["id"] == 16 ? audit.merge("action" => "delete") : audit },
      "idempotency_receipts" => checkpoint.fetch("idempotency_receipts").reject { |row| row["company_id"] == 2 && row["key"] == "web-1" }
    )
    before = held_rows

    load_recutover(refused)
    expect_problem(422, "checkpoint-refused")
    expect(body["lists"]).to eq(
      "locked_not_derived" => [240], "not_a_contract_audit" => [16],
      "dropped_entry" => [230], "dropped_idempotency_receipt" => ["2/web-1"]
    )
    expect(body["detail"]).to end_with("nothing loaded")
    expect(held_rows).to eq(before)
  end

  describe "what the call must carry" do
    before { checkpoint }

    it "refuses a body the contract does not allow, and one that is not JSON, changing nothing" do
      before = held_rows
      entries = checkpoint.fetch("entries")

      [
        checkpoint.except("idempotency_receipts"),
        checkpoint.merge("outbox" => []),
        checkpoint.merge("entries" => entries.map { |entry| entry["id"] == 240 ? entry.except("version") : entry }),
        checkpoint.merge("entries" => entries.map { |entry| entry["id"] == 240 ? entry.merge("version" => "2") : entry }),
        checkpoint.merge("reservations" => checkpoint.fetch("reservations").map { |row| row.merge("disposition" => "released") }),
        checkpoint.merge("entry_audits" => checkpoint.fetch("entry_audits").map { |audit| audit.except("id") }),
        checkpoint.merge("reservation_operations" => checkpoint.fetch("reservation_operations").map { |row| row.merge("operation_id" => "op-1") }),
        checkpoint.merge("idempotency_receipts" => checkpoint.fetch("idempotency_receipts").map { |row| row.except("key") })
      ].each do |payload|
        load_recutover(payload, carried: generation)
        expect_problem(400, "invalid-request")
      end

      post "/internal/v1/handoff/recutover/checkpoint", params: "{not json", headers: handoff_headers(generation:)
      expect_problem(400, "invalid-request")
      expect(held_rows).to eq(before)
    end

    it "refuses a generation the body and X-Ownership-Generation disagree on, and a call without either header it needs" do
      before = held_rows

      load_recutover(checkpoint, carried: 7)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("body generation differs from X-Ownership-Generation")

      load_recutover(headers: handoff_headers)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Ownership-Generation")

      load_recutover(headers: handoff_headers(generation:).except("X-Request-Id"))
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Request-Id")
      expect(held_rows).to eq(before)
    end

    it "refuses a call without the handoff tool's token, a user token among them, as unauthenticated" do
      before = held_rows

      [
        handoff_headers(generation:).except("Authorization"),
        handoff_headers(generation:, token: handoff_token(key: "another-key")),
        handoff_headers(generation:, token: handoff_token(aud: "projection", sub: "service:timekeeping-relay")),
        handoff_headers(generation:).merge("Authorization" => "Bearer #{user_token(user_token_claims(company_id: 1))}")
      ].each do |headers|
        load_recutover(headers:)
        expect_problem(401, "unauthenticated")
      end
      expect(held_rows).to eq(before)
    end
  end
end
