# frozen_string_literal: true

require "rails_helper"

# Steps 4 and 5 of the re-cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5): the checkpoint
# taken out of the prepared application, the outgoing `monolith` owner,
# replacing what Timekeeping still holds from before the rollback, and the
# entry and audit id sequences set above it (§10.3). The checkpoint has the
# shape the existing application's Timekeeping::LocalCheckpoint takes, which
# is the rollback's (handoff_api.json#/$defs/taken_checkpoint).
RSpec.describe RecutoverLoad do
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

  def load!(checkpoint = self.checkpoint) = described_class.call(checkpoint)

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

  # Sequences are not rolled back with a spec's transaction, so the sequence
  # specs set them to a known value and put them back afterwards.
  def sequence(name) = Entry.connection.select_rows("SELECT last_value, is_called FROM #{name}").sole

  def next_id(name) = Entry.connection.select_value("SELECT nextval('#{name}')")

  def restart!(name, value, called) = Entry.connection.select_value("SELECT setval('#{name}', #{value}, #{called})")

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

  describe "where the handoff must be" do
    {
      "admission still open" => { state: "open" },
      "admission closed, not yet frozen (settle may still be running)" => { state: "closed" },
      "frozen at another generation" => { generation: 7 },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy" },
      "frozen while Timekeeping is the outgoing owner (a rollback)" => { owner: "timekeeping" }
    }.each do |name, ownership|
      it "refuses with #{name}, and loads nothing" do
        checkpoint
        ownership!(**ownership)
        before = held_rows

        expect { load! }.to raise_error(described_class::OutOfStep, /load expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end

    it "holds the record FOR SHARE before it reads anything else" do
      checkpoint
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end

      load!

      ActiveSupport::Notifications.unsubscribe(subscriber)
      first_read = statements.index { |sql| sql.include?("FROM \"ownerships\"") && sql.include?("FOR SHARE") }
      expect(first_read).not_to be_nil
      expect(statements.first(first_read)).to all(satisfy { |sql| !sql.match?(/"(entries|reservations|entry_audits|reservation_operations|idempotency_receipts)"/) })
    end
  end

  describe "a loaded checkpoint" do
    it "answers what it loaded, part by part" do
      expect(load!).to eq(
        described_class::Loaded.new(entries: 6, reservations: 4, entry_audits: 6, reservation_operations: 6, idempotency_receipts: 3)
      )
    end

    it "leaves Timekeeping holding exactly the checkpoint: taken again, it is the same, part for part (§13 item 3)" do
      load!
      ownership!(owner: "timekeeping")

      expect(CheckpointTake.take(generation:)).to eq(checkpoint)
    end

    it "writes over the entries Timekeeping held with the versions the prepared application reached" do
      load!

      expect(Entry.order(:id).pluck(:id, :version)).to eq([[101, 4], [102, 2], [103, 2], [104, 1], [230, 5], [240, 2]])
      expect(Entry.find(101).updated_at).to eq(Time.utc(2026, 11, 12, 10, 20, 30, 7))
      expect(Entry.find(102).discarded_at).to eq(Time.utc(2026, 11, 12, 10, 20, 30, 7))
    end

    it "keeps every value as carried and runs no writer's rule (§8 item 1)" do
      load!

      expect(Entry.order(:id).pluck(:duration)).to eq([0.1, 479.99999, 90.7, 90.7, 90.7, 45.5])
      expect(Entry.find(102).note).to be_nil
      expect(Entry.find(230)).to have_attributes(source: "mcp", review_status: "pending_review", agent_id: 4, proof_metadata: { "tags" => [nil, "a"] })
      expect(Entry.find(240)).to have_attributes(company_id: 2, source: "manual", review_status: "not_required", agent_id: nil)
    end

    it "replaces the reservations with the checkpoint's, so an F2 release stays released and locked follows (§7.1)" do
      load!

      expect(Reservation.order(:entry_id).map(&:to_value)).to eq(checkpoint.reservations)
      expect(Entry.includes(:reservations).order(:id).to_h { |entry| [entry.id, entry.locked?] })
        .to eq(101 => false, 102 => false, 103 => true, 104 => false, 230 => true, 240 => true)
    end

    it "carries the audit rows with their ids, and the receipts of both tenants, so a retry after the re-cutover replays" do
      load!

      expect(EntryAudit.order(:id).pluck(:id, :entry_id, :version)).to eq(
        [[11, 101, 1], [12, 101, 2], [13, 230, 1], [14, 101, 4], [15, 102, 2], [16, 240, 1]]
      )
      expect(ReservationOperation.find_by(operation_id: released_draft_operation)).to have_attributes(state: "committed", kind: "discard")
      expect(ReservationOperation.find_by(operation_id: aborted_operation)).to have_attributes(state: "aborted", invoice_id: 603)
      expect(IdempotencyReceipt.find_by(company_id: 2, key: "web-2").replay("d3")).to eq([201, { "entry" => { "id" => 240 } }])
      expect(IdempotencyReceipt.find_by(company_id: 1, key: "web-1").replay("d1")).to eq([201, { "entry" => { "id" => 101, "duration" => 0.1 } }])
    end

    it "writes no outbox snapshot and keeps the delivered ones: the projection already holds these versions" do
      before = OutboxSnapshot.order(:id).map(&:attributes)

      load!

      expect(OutboxSnapshot.order(:id).map(&:attributes)).to eq(before)
      expect(OutboxSnapshot.undelivered).to be_empty
    end

    it "loads the same checkpoint again to the same tables, so a resumed handoff can run it twice" do
      load!
      after_first = held_rows.drop(1).values_at(0, 3)

      expect(load!).to eq(load!)
      expect(held_rows.drop(1).values_at(0, 3)).to eq(after_first)
      ownership!(owner: "timekeeping")
      expect(CheckpointTake.take(generation:)).to eq(checkpoint)
    end

    it "leaves the record frozen: only the fence flips it" do
      load!

      expect(Ownership.current.summary).to eq("generation 6, owner monolith, state frozen")
    end

    describe "the id sequences (§10.3)" do
      around do |example|
        saved = %w[entries_id_seq entry_audits_id_seq].index_with { |name| sequence(name) }
        example.run
      ensure
        saved.each { |name, (value, called)| restart!(name, value, called) }
      end

      it "sets both above the highest carried ids" do
        checkpoint
        restart!("entries_id_seq", 1, false)
        restart!("entry_audits_id_seq", 1, false)

        load!

        expect(next_id("entries_id_seq")).to eq(241)
        expect(next_id("entry_audits_id_seq")).to eq(17)
      end

      it "never moves either back" do
        checkpoint
        restart!("entries_id_seq", 900, true)
        restart!("entry_audits_id_seq", 900, true)

        load!

        expect(next_id("entries_id_seq")).to eq(901)
        expect(next_id("entry_audits_id_seq")).to eq(901)
      end
    end
  end

  # Each tampers with a row the prepared application wrote or changed, so
  # only the check named finds it.
  describe "a checkpoint that does not hold together" do
    def with(**parts) = checkpoint.with(**parts)

    def entries_with(id, **fields)
      checkpoint.entries.map { |entry| entry["id"] == id ? entry.merge(fields.transform_keys(&:to_s)) : entry }
    end

    {
      "an entry the contract does not allow" => [
        -> { with(entries: entries_with(240, duration: "1.5")) },
        { not_a_contract_entry: [240] }
      ],
      "a reservation of an entry the checkpoint does not hold" => [
        -> { with(reservations: checkpoint.reservations + [committed(999, 504, 1)]) },
        { reservation_without_its_entry: [999] }
      ],
      "a reservation of another tenant than its entry (§6.3)" => [
        -> { with(reservations: checkpoint.reservations.map { |reservation| reservation.entry_id == 240 ? reservation.with(company_id: 1) : reservation }) },
        { reservation_without_its_entry: [240] }
      ],
      "a provisional reservation: an operation crossing the handoff" => [
        -> { with(reservations: checkpoint.reservations.map { |reservation| reservation.entry_id == 240 ? reservation.with(state: :provisional, operation_id: SecureRandom.uuid) : reservation }) },
        { provisional_reservation: [240] }
      ],
      "an entry whose locked is not what its reservations derive" => [
        -> { with(entries: entries_with(102, locked: true)) },
        { locked_not_derived: [102] }
      ],
      "an audit row the contract does not allow" => [
        -> { with(entry_audits: checkpoint.entry_audits.map { |audit| audit["id"] == 16 ? audit.merge("action" => "delete") : audit }) },
        { not_a_contract_audit: [16] }
      ],
      "an audit row of another tenant than its entry (§6.3)" => [
        -> { with(entry_audits: checkpoint.entry_audits.map { |audit| audit["id"] == 16 ? audit.merge("company_id" => 1) : audit }) },
        { audit_without_its_entry: [16] }
      ],
      "an operation still prepared" => [
        -> { with(reservation_operations: checkpoint.reservation_operations.map { |row| row["invoice_id"] == 602 ? row.merge("state" => "prepared") : row }) },
        { not_a_terminal_receipt: ["602/6fa459ea-ee8a-4ca4-894e-db77e160355e"] }
      ],
      "an idempotency receipt the contract does not allow" => [
        -> { with(idempotency_receipts: checkpoint.idempotency_receipts.map { |row| row["key"] == "web-2" ? row.merge("status" => 500) : row }) },
        { not_a_contract_idempotency_receipt: ["2/web-2"] }
      ]
    }.each do |name, (given, lists)|
      it "refuses #{name}, listing it, and loads nothing" do
        refused = instance_exec(&given)
        before = held_rows

        expect { load!(refused) }.to raise_error(described_class::Refused) { |error| expect(error.lists).to eq(lists) }
        expect(held_rows).to eq(before)
      end
    end

    it "says why in its message" do
      refused = with(entries: entries_with(102, locked: true))

      expect { load!(refused) }.to raise_error(described_class::Refused, "Timekeeping checkpoint load: locked_not_derived 102; nothing loaded")
    end
  end

  # §13 item 3: rollback and re-cutover keep every write accepted on either
  # side. What Timekeeping accepted before the rollback is in the checkpoint
  # unless something lost it on the way, and the load must not replace it
  # with less.
  describe "a checkpoint that would drop what Timekeeping holds" do
    def with(**parts) = checkpoint.with(**parts)

    def without_entry(id)
      with(
        entries: checkpoint.entries.reject { |entry| entry["id"] == id },
        reservations: checkpoint.reservations.reject { |reservation| reservation.entry_id == id },
        entry_audits: checkpoint.entry_audits.reject { |audit| audit["entry_id"] == id }
      )
    end

    {
      "an entry Timekeeping holds that it does not carry" => [
        -> { without_entry(103) },
        { dropped_entry: [103] }
      ],
      "an entry carried at an older version than Timekeeping holds" => [
        -> { with(entries: checkpoint.entries.map { |entry| entry["id"] == 230 ? entry.merge("version" => 4) : entry }) },
        { dropped_entry: [230] }
      ],
      "an entry carried at the version Timekeeping holds with other content" => [
        -> { with(entries: checkpoint.entries.map { |entry| entry["id"] == 230 ? entry.merge("note" => "rewritten") : entry }) },
        { dropped_entry: [230] }
      ],
      "an audit row Timekeeping holds that it does not carry" => [
        -> { with(entry_audits: checkpoint.entry_audits.reject { |audit| audit["id"] == 12 }) },
        { dropped_entry_audit: [12] }
      ],
      "an audit row carried other than Timekeeping holds it" => [
        -> { with(entry_audits: checkpoint.entry_audits.map { |audit| audit["id"] == 13 ? audit.merge("actor" => "user:8") : audit }) },
        { dropped_entry_audit: [13] }
      ],
      "an operation receipt Timekeeping holds that it does not carry" => [
        -> { with(reservation_operations: checkpoint.reservation_operations.reject { |row| row["invoice_id"] == 701 }) },
        { dropped_reservation_operation: ["701/8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6"] }
      ],
      "an operation receipt carried with another outcome than Timekeeping holds" => [
        -> {
          with(reservation_operations: checkpoint.reservation_operations.map { |row| row["invoice_id"] == 601 ? row.merge("state" => "aborted") : row })
        },
        { dropped_reservation_operation: ["601/3d6f4e2a-8b1c-4d5e-9f0a-7b6c5d4e3f2a"] }
      ],
      "an idempotency receipt Timekeeping holds that it does not carry" => [
        -> { with(idempotency_receipts: checkpoint.idempotency_receipts.reject { |row| row["company_id"] == 2 && row["key"] == "web-1" }) },
        { dropped_idempotency_receipt: ["2/web-1"] }
      ],
      "an idempotency receipt carried with another answer than Timekeeping holds" => [
        -> {
          with(idempotency_receipts: checkpoint.idempotency_receipts.map { |row| row["key"] == "web-1" && row["company_id"] == 1 ? row.merge("response" => {}) : row })
        },
        { dropped_idempotency_receipt: ["1/web-1"] }
      ]
    }.each do |name, (given, lists)|
      it "refuses #{name}, listing it, and replaces nothing" do
        refused = instance_exec(&given)
        before = held_rows

        expect { load!(refused) }.to raise_error(described_class::Refused) { |error| expect(error.lists).to eq(lists) }
        expect(held_rows).to eq(before)
      end
    end

    it "lists every check that found something, together" do
      refused = without_entry(103).then do |partial|
        partial.with(idempotency_receipts: partial.idempotency_receipts.reject { |row| row["key"] == "web-2" || row["company_id"] == 2 })
      end

      expect { load!(refused) }.to raise_error(described_class::Refused) do |error|
        expect(error.lists).to eq(dropped_entry: [103], dropped_idempotency_receipt: ["2/web-1"])
      end
    end
  end
end
