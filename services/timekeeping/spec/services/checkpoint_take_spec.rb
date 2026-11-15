# frozen_string_literal: true

require "rails_helper"

# Step 4 of the rollback on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 4): the
# frozen checkpoint taken from Timekeeping, the outgoing owner, holding every
# entry, every reservation, the entry audit rows, the terminal
# invoice-operation receipts and the entry API's idempotency receipts.
RSpec.describe CheckpointTake do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 4 }

  let(:created_at) { Time.utc(2026, 11, 2, 9, 15, 30, 123_456) }
  let(:updated_at) { Time.utc(2026, 11, 3, 17, 45, 1, 654_321) }

  def freeze_handoff!(generation: self.generation, owner: "timekeeping", state: "frozen")
    Ownership.current.update!(generation:, owner:, state:)
  end

  def take!(generation: self.generation) = described_class.take(generation:)

  # Everything Timekeeping holds, row by row, to show the take wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  def audit!(entry, **attributes)
    entry.audits.create!(
      {
        company_id: entry.company_id, action: "update", version: entry.version, actor: "user:7", agent_id: nil,
        writer: "web", request_id: "req-#{entry.id}", audited_changes: { "note" => ["Prep", "Kitchen prep"] },
        created_at:
      }.merge(attributes)
    )
  end

  def operation!(invoice_id:, state:, **attributes)
    ReservationOperation.create!(
      { invoice_id:, operation_id: SecureRandom.uuid, state:, created_at:, updated_at: }.merge(attributes)
    )
  end

  # Two tenants, as Timekeeping holds them after a cutover and some writes:
  #
  # Fork & Leaf: an entry on a kept draft (active, edit lock) at version 3,
  # one on a non-draft with no lock, one held by a destroyed non-draft
  # (retained, edit lock, §7.3), and a discarded entry with no reservation.
  # Copper Kettle: an agent's entry pending review that was retained by a
  # discarded non-draft and then succeeded by a kept draft, so it holds only
  # the successor's reservation.
  let!(:on_draft) do
    entry!(company_id: fork_and_leaf, id: 101, version: 3, duration: 0.1, note: "Kitchen prep", created_at:, updated_at:)
  end
  let!(:unlocked_link) { entry!(company_id: fork_and_leaf, id: 102, duration: 479.99999, note: nil, created_at:, updated_at:) }
  let!(:retained) { entry!(company_id: fork_and_leaf, id: 103, version: 2, bill_status: "billed", created_at:, updated_at:) }
  let!(:discarded) do
    entry!(company_id: fork_and_leaf, id: 104, discarded_at: Time.utc(2026, 11, 4, 8, 0, 0, 1), created_at:, updated_at:)
  end
  let!(:agent_entry) do
    entry!(
      company_id: copper_kettle, id: 230, version: 5, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru" }, proof_url: "https://example.test/run/9",
      proof_metadata: { "commits" => 3, "verified" => false, "tags" => [nil, "a"] },
      external_run_id: "run-9", external_session_id: "session-2", created_at:, updated_at:
    )
  end

  let(:draft_operation) { "0f8e2c1a-5b4d-4e3f-9a2b-1c0d9e8f7a6b" }
  let(:noop_abort) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }

  before do
    reservation!(on_draft, invoice_id: 501)
    reservation!(unlocked_link, invoice_id: 502, edit_lock: false)
    reservation!(retained, invoice_id: 503, disposition: "retained")
    reservation!(agent_entry, invoice_id: 601)

    audit!(on_draft, action: "create", version: 1, audited_changes: { "duration" => 0.1 })
    audit!(on_draft, version: 2)
    audit!(agent_entry, action: "create", version: 1, actor: "agent:4", agent_id: 4, writer: "agent", audited_changes: {})

    operation!(
      invoice_id: 501, operation_id: draft_operation, state: "committed", company_id: fork_and_leaf, kind: "save",
      invoice_state: "draft", entry_ids: [101]
    )
    operation!(
      invoice_id: 601, state: "committed", company_id: copper_kettle, kind: "save", invoice_state: "draft", entry_ids: [230]
    )
    # An abort of an operation never prepared: the no-op receipt (§9.3).
    operation!(invoice_id: 701, operation_id: noop_abort, state: "aborted")

    IdempotencyReceipt.create!(
      company_id: fork_and_leaf, key: "web-1", request_digest: "d1", status: 201,
      response: { "entry" => { "id" => 101, "duration" => 0.1 } }, created_at:
    )
    IdempotencyReceipt.create!(
      company_id: copper_kettle, key: "web-1", request_digest: "d2", status: 200, response: { "entry" => nil }, created_at:
    )
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { owner: "timekeeping", state: "open" },
      "admission closed, not yet frozen (settle may still be running)" => { owner: "timekeeping", state: "closed" },
      "frozen at another generation" => { generation: 5, owner: "timekeeping", state: "frozen" },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy", state: "frozen" },
      "frozen while the prepared application is the outgoing owner (a re-cutover)" => { owner: "monolith", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and takes nothing" do
        freeze_handoff!(**ownership)
        before = held_rows

        expect { take! }.to raise_error(described_class::OutOfStep, /checkpoint expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end

    it "refuses on a database where no handoff has run" do
      expect { take! }.to raise_error(described_class::OutOfStep, /checkpoint expects generation 4 in state frozen/)
    end

    it "holds the record FOR SHARE before it reads anything else" do
      freeze_handoff!
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end

      take!

      ActiveSupport::Notifications.unsubscribe(subscriber)
      first_read = statements.index { |sql| sql.include?("FROM \"ownerships\"") && sql.include?("FOR SHARE") }
      expect(first_read).not_to be_nil
      expect(statements.first(first_read)).to all(satisfy { |sql| !sql.match?(/FROM "(entries|reservations|entry_audits|reservation_operations|idempotency_receipts)"/) })
    end
  end

  describe "a settled, frozen handoff" do
    before { freeze_handoff! }

    let(:checkpoint) { take! }

    it "names the generation it was taken at and the highest entry id (§10.3)" do
      expect(checkpoint.generation).to eq(generation)
      expect(checkpoint.highest_entry_id).to eq(230)
    end

    it "carries every entry of both tenants, discarded ones included, as the contract's full entry" do
      expect(checkpoint.entries.pluck("id")).to eq([101, 102, 103, 104, 230])
      expect(checkpoint.entries.pluck("company_id")).to eq([1, 1, 1, 1, 2])
      checkpoint.entries.each { |entry| expect(contract_errors("common", "#/$defs/entry", entry)).to be_empty }
      expect(checkpoint.entries).to eq(Entry.includes(:reservations).order(:id).map(&:to_contract))
    end

    it "keeps the versions Timekeeping holds: the projection already has them, so nothing is renumbered" do
      expect(checkpoint.entries.to_h { |entry| [entry.fetch("id"), entry.fetch("version")] })
        .to eq(101 => 3, 102 => 1, 103 => 2, 104 => 1, 230 => 5)
    end

    it "derives locked from the reservations (§7.1)" do
      expect(checkpoint.entries.to_h { |entry| [entry.fetch("id"), entry.fetch("locked")] })
        .to eq(101 => true, 102 => false, 103 => true, 104 => false, 230 => true)
    end

    it "copies every value exactly as stored (§8 item 1)" do
      expect(checkpoint.entries.pluck("duration")).to eq([0.1, 479.99999, 90.7, 90.7, 90.7])
      expect(checkpoint.entries.first).to include(
        "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z", "note" => "Kitchen prep"
      )
      expect(checkpoint.entries.second).to include("note" => nil)
      expect(checkpoint.entries.fourth).to include("discarded_at" => "2026-11-04T08:00:00.000001Z")
      expect(checkpoint.entries.last).to include(
        "agent_id" => 4, "review_status" => "pending_review", "source" => "mcp", "source_metadata" => { "mcp_server" => "miru" },
        "proof_metadata" => { "commits" => 3, "verified" => false, "tags" => [nil, "a"] },
        "external_run_id" => "run-9", "external_session_id" => "session-2"
      )
    end

    it "carries each entry's reservations: owner, tenant, state, edit lock and disposition" do
      expect(checkpoint.reservations).to eq(
        [
          [101, 501, 1, :active, true],
          [102, 502, 1, :active, false],
          [103, 503, 1, :retained, true],
          [230, 601, 2, :active, true]
        ].map do |entry_id, invoice_id, company_id, disposition, edit_lock|
          TimekeepingReservations::Reservation.new(
            entry_id:, invoice_id:, company_id:, operation_id: nil, state: :committed, disposition:, edit_lock:
          )
        end
      )
    end

    it "carries a destroyed non-draft's retained reservation by its own owner data (§7.3)" do
      expect(checkpoint.reservations.find { |reservation| reservation.entry_id == 103 })
        .to have_attributes(invoice_id: 503, company_id: 1, state: :committed, disposition: :retained, edit_lock: true)
    end

    it "carries the entry audit rows with their ids, in id order" do
      audits = EntryAudit.order(:id).to_a

      expect(checkpoint.entry_audits).to eq(
        audits.map do |audit|
          {
            "id" => audit.id, "entry_id" => audit.entry_id, "company_id" => audit.company_id, "version" => audit.version,
            "action" => audit.action, "actor" => audit.actor, "agent_id" => audit.agent_id, "writer" => audit.writer,
            "request_id" => audit.request_id, "audited_changes" => audit.audited_changes,
            "created_at" => "2026-11-02T09:15:30.123456Z"
          }
        end
      )
      expect(checkpoint.entry_audits.pluck("entry_id", "version", "action"))
        .to eq([[101, 1, "create"], [101, 2, "update"], [230, 1, "create"]])
      expect(checkpoint.entry_audits.first.fetch("audited_changes")).to eq("duration" => 0.1)
    end

    it "carries every terminal invoice-operation receipt, the no-op abort of one never prepared included" do
      expect(checkpoint.reservation_operations.pluck("invoice_id", "state")).to eq([[501, "committed"], [601, "committed"], [701, "aborted"]])
      expect(checkpoint.reservation_operations.first).to eq(
        "invoice_id" => 501, "operation_id" => draft_operation, "company_id" => 1, "kind" => "save",
        "invoice_state" => "draft", "entry_ids" => [101], "state" => "committed",
        "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
      )
      expect(checkpoint.reservation_operations.last).to include(
        "operation_id" => noop_abort, "company_id" => nil, "kind" => nil, "invoice_state" => nil, "entry_ids" => []
      )
    end

    it "carries the entry API's idempotency receipts of both tenants, so a retry after the rollback replays" do
      expect(checkpoint.idempotency_receipts).to eq(
        [
          {
            "company_id" => 1, "key" => "web-1", "request_digest" => "d1", "status" => 201,
            "response" => { "entry" => { "id" => 101, "duration" => 0.1 } }, "created_at" => "2026-11-02T09:15:30.123456Z"
          },
          {
            "company_id" => 2, "key" => "web-1", "request_digest" => "d2", "status" => 200,
            "response" => { "entry" => nil }, "created_at" => "2026-11-02T09:15:30.123456Z"
          }
        ]
      )
    end

    it "is carried through JSON unchanged" do
      parts = checkpoint.to_h.except(:generation, :reservations)

      expect(JSON.parse(JSON.generate(parts)).transform_keys(&:to_sym)).to eq(parts)
    end

    it "writes nothing, and leaves the record frozen for the fence to flip" do
      before = held_rows

      checkpoint

      expect(held_rows).to eq(before)
      expect(Ownership.current.summary).to eq("generation 4, owner timekeeping, state frozen")
    end

    it "takes an empty checkpoint from a Timekeeping that holds nothing" do
      [Reservation, EntryAudit, OutboxSnapshot, Entry, ReservationOperation, IdempotencyReceipt].each(&:delete_all)

      expect(checkpoint).to eq(
        described_class::Checkpoint.new(
          generation:, entries: [], reservations: [], entry_audits: [], reservation_operations: [], idempotency_receipts: []
        )
      )
      expect(checkpoint.highest_entry_id).to be_nil
    end
  end

  describe "an operation settle did not resolve (§10.5 step 2: no pending billing operation crosses)" do
    before { freeze_handoff! }

    def unsettled_lists
      take!
      raise "expected #{described_class}::Unsettled"
    rescue described_class::Unsettled => e
      e.lists
    end

    it "refuses an operation still prepared and its provisional reservation, and takes nothing" do
      pending = operation!(
        invoice_id: 801, state: "prepared", company_id: copper_kettle, kind: "save", invoice_state: "draft", entry_ids: [230, 231]
      )
      provisional = entry!(company_id: copper_kettle, id: 231)
      provisional.reservations.create!(
        invoice_id: 801, company_id: copper_kettle, state: "provisional", disposition: "active", edit_lock: true,
        operation_id: pending.operation_id
      )
      before = held_rows

      expect(unsettled_lists).to eq(provisional_reservation: [231], unresolved_operation: ["801/#{pending.operation_id}"])
      expect(held_rows).to eq(before)
    end

    it "says why in its message" do
      pending = operation!(invoice_id: 801, state: "prepared", company_id: copper_kettle, kind: "discard", invoice_state: "draft")

      expect { take! }.to raise_error(described_class::Unsettled, "Timekeeping checkpoint: unresolved_operation 801/#{pending.operation_id}; settle first, nothing taken")
    end
  end
end
