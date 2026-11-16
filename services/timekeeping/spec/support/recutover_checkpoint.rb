# frozen_string_literal: true

# The re-cutover's checkpoint (docs/architecture/timekeeping-soa.md §10.2
# step 6, §10.5 step 4), for the specs of the steps that take it on
# Timekeeping's side: RecutoverLoad and RecutoverReconcile. Timekeeping holds
# what it held when the rollback took its checkpoint, and `checkpoint` is
# what the prepared application then held at the re-cutover, in the shape
# the existing application's Timekeeping::LocalCheckpoint takes, which is the
# rollback's (handoff_api.json#/$defs/taken_checkpoint).
RSpec.shared_context "a re-cutover checkpoint" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:rollback_generation) { 5 }
  let(:generation) { 6 }

  let(:created_at) { Time.utc(2026, 11, 2, 9, 15, 30, 123_456) }
  let(:updated_at) { Time.utc(2026, 11, 3, 17, 45, 1, 654_321) }
  let(:later) { "2026-11-12T10:20:30.000007Z" }

  let(:released_draft_operation) { "1b4e28ba-2fa1-41d2-883f-0016d3cca427" }
  let(:new_draft_operation) { "6fa459ea-ee8a-4ca4-894e-db77e160355e" }
  let(:aborted_operation) { "c56a4180-65aa-42ec-a945-5fd21dec0538" }

  def ownership!(generation: self.generation, owner: "monolith", state: "frozen")
    Ownership.current.update!(generation:, owner:, state:)
  end

  # Everything Timekeeping holds, row by row, to show a refusal wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  def committed(entry_id, invoice_id, company_id, disposition: :active, edit_lock: true)
    TimekeepingReservations::Reservation.new(
      entry_id:, invoice_id:, company_id:, operation_id: nil, state: :committed, disposition:, edit_lock:
    )
  end

  # What Timekeeping still holds from before the rollback, on two tenants, as
  # in CheckpointTake's spec: on Fork & Leaf an entry on a kept draft at
  # version 3, an unlocked link, a destroyed non-draft's retained entry and a
  # discarded entry; on Copper Kettle an agent's entry on a kept draft. Audit
  # rows, committed receipts, a no-op abort, idempotency receipts of both
  # tenants under one key, and a delivered outbox snapshot.
  before do
    on_draft = entry!(company_id: fork_and_leaf, id: 101, version: 3, duration: 0.1, note: "Kitchen prep", created_at:, updated_at:)
    unlocked_link = entry!(company_id: fork_and_leaf, id: 102, duration: 479.99999, note: nil, created_at:, updated_at:)
    retained = entry!(company_id: fork_and_leaf, id: 103, version: 2, bill_status: "billed", created_at:, updated_at:)
    entry!(company_id: fork_and_leaf, id: 104, discarded_at: Time.utc(2026, 11, 4, 8, 0, 0, 1), created_at:, updated_at:)
    agent_entry = entry!(
      company_id: copper_kettle, id: 230, version: 5, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru" }, proof_metadata: { "tags" => [nil, "a"] }, created_at:, updated_at:
    )

    reservation!(on_draft, invoice_id: 501)
    reservation!(unlocked_link, invoice_id: 502, edit_lock: false)
    reservation!(retained, invoice_id: 503, disposition: "retained")
    reservation!(agent_entry, invoice_id: 601)

    [[11, on_draft, "create", 1], [12, on_draft, "update", 2], [13, agent_entry, "create", 1]].each do |id, entry, action, version|
      EntryAudit.create!(
        id:, entry_id: entry.id, company_id: entry.company_id, action:, version:, actor: "user:7", agent_id: nil,
        writer: "web", request_id: "req-#{id}", audited_changes: { "note" => [nil, "Kitchen prep"] }, created_at:
      )
    end

    ReservationOperation.create!(
      invoice_id: 501, operation_id: "0f8e2c1a-5b4d-4e3f-9a2b-1c0d9e8f7a6b", state: "committed", company_id: fork_and_leaf,
      kind: "save", invoice_state: "draft", entry_ids: [101], created_at:, updated_at:
    )
    ReservationOperation.create!(
      invoice_id: 601, operation_id: "3d6f4e2a-8b1c-4d5e-9f0a-7b6c5d4e3f2a", state: "committed", company_id: copper_kettle,
      kind: "save", invoice_state: "draft", entry_ids: [230], created_at:, updated_at:
    )
    ReservationOperation.create!(invoice_id: 701, operation_id: "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6", state: "aborted", created_at:, updated_at:)

    IdempotencyReceipt.create!(
      company_id: fork_and_leaf, key: "web-1", request_digest: "d1", status: 201,
      response: { "entry" => { "id" => 101, "duration" => 0.1 } }, created_at:
    )
    IdempotencyReceipt.create!(company_id: copper_kettle, key: "web-1", request_digest: "d2", status: 200, response: { "entry" => nil }, created_at:)

    OutboxSnapshot.create!(
      entry_id: 101, company_id: fork_and_leaf, version: 3, snapshot: OutboxSnapshot.of(on_draft.reload), request_id: "req-12",
      delivered_at: updated_at
    )
  end

  # The rollback's checkpoint: what the prepared application loaded from
  # Timekeeping (CheckpointTake), so the starting point of everything it
  # then held.
  let(:rolled_back) do
    ownership!(generation: rollback_generation, owner: "timekeeping")
    CheckpointTake.take(generation: rollback_generation).tap { ownership! }
  end

  # The prepared application's checkpoint at the re-cutover: the rollback's,
  # plus what the monolith owner accepted after it. On Fork & Leaf the draft
  # holding 101 was discarded, which released it (F2) at version 4, and 102
  # was discarded at version 2. On Copper Kettle a new entry, 240, was put on
  # a new draft, with its own audit rows, receipts and idempotency receipt.
  let(:checkpoint) do
    entries = rolled_back.entries.map do |entry|
      case entry.fetch("id")
      when 101 then entry.merge("version" => 4, "locked" => false, "updated_at" => later)
      when 102 then entry.merge("version" => 2, "discarded_at" => later, "updated_at" => later)
      else entry
      end
    end
    new_entry = entries.last.merge(
      "id" => 240, "version" => 2, "agent_id" => nil, "review_status" => "not_required", "source" => "manual",
      "source_metadata" => {}, "proof_metadata" => {}, "duration" => 45.5, "locked" => true, "created_at" => later, "updated_at" => later
    )

    audit = rolled_back.entry_audits.first
    new_audits = [[14, 101, 1, 4], [15, 102, 1, 2], [16, 240, 2, 1]].map do |id, entry_id, company_id, version|
      audit.merge("id" => id, "entry_id" => entry_id, "company_id" => company_id, "version" => version, "request_id" => "local-#{id}", "created_at" => later)
    end

    receipt = rolled_back.reservation_operations.first
    new_receipts = [
      receipt.merge("operation_id" => released_draft_operation, "kind" => "discard", "updated_at" => later),
      receipt.merge(
        "invoice_id" => 602, "operation_id" => new_draft_operation, "company_id" => 2, "entry_ids" => [240],
        "created_at" => later, "updated_at" => later
      ),
      receipt.merge("invoice_id" => 603, "operation_id" => aborted_operation, "company_id" => 2, "entry_ids" => [240], "state" => "aborted")
    ]

    CheckpointTake::Checkpoint.new(
      generation:,
      entries: entries + [new_entry],
      reservations: rolled_back.reservations.reject { |reservation| reservation.entry_id == 101 } + [committed(240, 602, 2)],
      entry_audits: rolled_back.entry_audits + new_audits,
      reservation_operations: (rolled_back.reservation_operations + new_receipts).sort_by { |row| row.values_at("invoice_id", "operation_id") },
      idempotency_receipts: rolled_back.idempotency_receipts + [
        { "company_id" => 2, "key" => "web-2", "request_digest" => "d3", "status" => 201, "response" => { "entry" => { "id" => 240 } }, "created_at" => later }
      ]
    )
  end
end
