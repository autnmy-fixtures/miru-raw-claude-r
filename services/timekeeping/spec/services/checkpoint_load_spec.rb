# frozen_string_literal: true

require "rails_helper"

# Steps 4 and 5 of the first cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.5): the legacy owner's checkpoint
# loaded into Timekeeping exactly as it carries it, and the id sequence set
# above it (§10.3). The checkpoint here has the shape the existing
# application's Timekeeping::LegacyCheckpoint takes: every entry as
# common.json's full entry at version 1, and committed reservations.
RSpec.describe CheckpointLoad do
  def checkpointed(id:, company_id:, **fields)
    {
      "id" => id, "company_id" => company_id, "version" => 1,
      "project_id" => 10 + company_id, "user_id" => 7, "agent_id" => nil, "duration" => 90.7,
      "work_date" => "2026-11-02", "note" => "Kitchen prep", "bill_status" => "unbilled",
      "review_status" => "not_required", "locked" => false, "source" => "manual",
      "source_metadata" => {}, "proof_url" => nil, "proof_metadata" => {},
      "external_run_id" => nil, "external_session_id" => nil, "discarded_at" => nil,
      "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
    }.merge(fields.transform_keys(&:to_s))
  end

  def committed(entry, invoice_id:, disposition: :active, edit_lock: true)
    TimekeepingReservations::Reservation.new(
      entry_id: entry.fetch("id"), invoice_id:, company_id: entry.fetch("company_id"),
      operation_id: nil, state: :committed, disposition:, edit_lock:
    )
  end

  # Two tenants: on A an entry on a kept draft (locked), one on a non-draft
  # with no lock (an unlocked link), one held by a discarded non-draft
  # (retained) and a discarded entry; on B an F2 release, which carries no
  # reservation, and an agent's entry pending review.
  let(:locked) { checkpointed(id: 101, company_id: 1, locked: true, duration: 0.1) }
  let(:unlocked_link) { checkpointed(id: 102, company_id: 1, duration: 479.99999, note: nil) }
  let(:retained) { checkpointed(id: 103, company_id: 1, locked: true, bill_status: "billed") }
  let(:discarded) { checkpointed(id: 104, company_id: 1, discarded_at: "2026-11-04T08:00:00.000001Z") }
  let(:released) { checkpointed(id: 205, company_id: 2, bill_status: "non_billable") }
  let(:agent_entry) do
    checkpointed(
      id: 230, company_id: 2, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru" }, proof_url: "https://example.test/run/9",
      proof_metadata: { "commits" => 3, "verified" => false, "branch" => "main" },
      external_run_id: "run-9", external_session_id: "session-2"
    )
  end
  let(:entries) { [locked, unlocked_link, retained, discarded, released, agent_entry] }
  let(:reservations) do
    [
      committed(locked, invoice_id: 501),
      committed(unlocked_link, invoice_id: 502, edit_lock: false),
      committed(retained, invoice_id: 503, disposition: :retained)
    ]
  end

  def freeze_handoff!(generation: 1, owner: "legacy", state: "frozen")
    Ownership.current.update!(generation:, owner:, state:)
  end

  def load!(generation: 1, entries: self.entries, reservations: self.reservations)
    described_class.call(generation:, entries:, reservations:, request_id: "handoff-1")
  end

  # Sequences are not rolled back with a spec's transaction, so the sequence
  # specs start it where a fresh database has it.
  def sequence = Entry.connection.select_rows("SELECT last_value, is_called FROM entries_id_seq").sole

  def next_id = Entry.connection.select_value("SELECT nextval('entries_id_seq')")

  def written
    [Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation].map(&:count)
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { generation: 1, owner: "legacy", state: "open" },
      "admission closed, not frozen" => { generation: 1, owner: "legacy", state: "closed" },
      "frozen at another generation" => { generation: 2, owner: "legacy", state: "frozen" },
      "frozen while Timekeeping is the outgoing owner" => { generation: 1, owner: "timekeeping", state: "frozen" },
      "frozen while the prepared application is the outgoing owner" => { generation: 1, owner: "monolith", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and loads nothing" do
        freeze_handoff!(**ownership)

        expect { load! }.to raise_error(described_class::OutOfStep, /nothing (loaded|changed)/)
        expect(written).to all(be_zero)
      end
    end

    it "refuses on a database where no handoff has run" do
      expect { load! }.to raise_error(described_class::OutOfStep, /expects generation 1 in state frozen/)
    end
  end

  describe "a loaded checkpoint" do
    before { freeze_handoff! }

    it "holds every entry of both tenants exactly as the checkpoint carries it" do
      expect(load!).to eq(described_class::Loaded.new(entries: 6, reservations: 3))

      loaded = Entry.includes(:reservations).order(:id).map(&:to_contract)
      expect(loaded).to eq(entries)
      loaded.each { |entry| expect(contract_errors(:common, "#/$defs/entry", entry)).to be_empty }
    end

    it "keeps the stored float and the microseconds, and runs no writer's rule" do
      load!

      expect(Entry.order(:id).pluck(:duration)).to eq([0.1, 479.99999, 90.7, 90.7, 90.7, 90.7])
      expect(Entry.find(104).discarded_at).to eq(Time.utc(2026, 11, 4, 8, 0, 0, 1))
      expect(Entry.find(101).updated_at).to eq(Time.utc(2026, 11, 3, 17, 45, 1, 654_321))
      expect(Entry.find(102).note).to be_nil
      expect(Entry.find(230)).to have_attributes(source: "mcp", review_status: "pending_review", agent_id: 4)
    end

    it "holds each reservation as committed by its invoice, and derives locked from it (§7.1)" do
      load!

      expect(Reservation.all.map(&:to_value)).to match_array(reservations)
      expect(Entry.includes(:reservations).order(:id).to_h { |entry| [entry.id, entry.locked?] })
        .to eq(101 => true, 102 => false, 103 => true, 104 => false, 205 => false, 230 => false)
    end

    it "writes one undelivered snapshot per entry at its version, carrying the handoff's request id" do
      load!

      snapshots = OutboxSnapshot.undelivered.to_a
      expect(snapshots.map { |row| [row.entry_id, row.company_id, row.version, row.request_id] })
        .to eq(entries.map { |entry| [entry["id"], entry["company_id"], 1, "handoff-1"] })
      snapshots.each do |row|
        expect(contract_errors(:entry_snapshot, "#/$defs/entry_snapshot", row.snapshot)).to be_empty
        expect(row.snapshot["data"]).to eq(entries.find { |entry| entry["id"] == row.entry_id }.except("id", "company_id", "version"))
      end
    end

    it "writes no audit row, receipt or operation: a load is not a writer's change" do
      load!

      expect([EntryAudit.count, IdempotencyReceipt.count, ReservationOperation.count]).to eq([0, 0, 0])
    end

    it "sets the id sequence above the highest loaded id (§10.3)" do
      Entry.connection.select_value("SELECT setval('entries_id_seq', 1, false)")

      load!

      expect(next_id).to eq(231)
    end

    it "never moves the id sequence back" do
      Entry.connection.select_value("SELECT setval('entries_id_seq', 900)")

      load!

      expect(next_id).to eq(901)
    end

    it "loads an empty checkpoint as nothing, and leaves the sequence alone" do
      before = sequence

      expect(load!(entries: [], reservations: [])).to eq(described_class::Loaded.new(entries: 0, reservations: 0))
      expect(written).to all(be_zero)
      expect(sequence).to eq(before)
    end

    it "refuses a second load once Timekeeping holds entries, and changes nothing" do
      load!

      expect { load! }.to raise_error(described_class::AlreadyLoaded, /nothing loaded/)
      expect(written).to eq([6, 3, 6, 0, 0, 0])
    end

    it "leaves the record frozen: only the fence flips it" do
      load!

      expect(Ownership.current.summary).to eq("generation 1, owner legacy, state frozen")
    end
  end

  describe "a checkpoint that does not hold together" do
    before { freeze_handoff! }

    {
      "an entry the contract does not allow" => [
        -> { [entries.map { |entry| entry["id"] == 102 ? entry.merge("duration" => "1.5") : entry }, reservations] },
        { not_a_contract_entry: [102] }
      ],
      "a reservation of an entry the checkpoint does not hold" => [
        -> { [entries - [locked], reservations] },
        { reservation_without_its_entry: [101] }
      ],
      "a reservation of another tenant than its entry (§6.3)" => [
        -> { [entries, reservations.map { |reservation| reservation.entry_id == 102 ? reservation.with(company_id: 2) : reservation }] },
        { reservation_without_its_entry: [102] }
      ],
      "a provisional reservation: an operation crossing the handoff" => [
        -> { [entries, reservations.map { |reservation| reservation.entry_id == 101 ? reservation.with(state: :provisional, operation_id: SecureRandom.uuid) : reservation }] },
        { provisional_reservation: [101] }
      ],
      "an entry whose locked is not what its reservations derive" => [
        -> { [entries.map { |entry| entry["id"] == 205 ? entry.merge("locked" => true) : entry }, reservations] },
        { locked_not_derived: [205] }
      ]
    }.each do |name, (checkpoint, lists)|
      it "refuses #{name}, listing it, and loads nothing" do
        given_entries, given_reservations = instance_exec(&checkpoint)

        expect { load!(entries: given_entries, reservations: given_reservations) }
          .to raise_error(described_class::Refused) { |error| expect(error.lists).to eq(lists) }
        expect(written).to all(be_zero)
      end
    end
  end
end
