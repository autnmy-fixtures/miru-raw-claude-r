# frozen_string_literal: true

require "rails_helper"

# Step 6 of the first cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.5, §10.4): what Timekeeping holds
# after CheckpointLoad compared, exactly, with the checkpoint the legacy owner
# gave. The checkpoint has the shape the existing application's
# Timekeeping::LegacyCheckpoint takes: every entry as common.json's full
# entry at version 1, and committed reservations.
RSpec.describe CheckpointReconcile do
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

  def load!
    CheckpointLoad.call(generation: 1, entries:, reservations:, request_id: "handoff-1")
  end

  def reconcile!(generation: 1, entries: self.entries, reservations: self.reservations)
    described_class.call(generation:, entries:, reservations:)
  end

  def reconcile_differences(**checkpoint)
    reconcile!(**checkpoint)
    raise "expected #{described_class}::Differs"
  rescue described_class::Differs => e
    e.lists
  end

  # Everything Timekeeping holds, row by row, to show reconcile wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { generation: 1, owner: "legacy", state: "open" },
      "admission closed, not frozen" => { generation: 1, owner: "legacy", state: "closed" },
      "frozen at another generation" => { generation: 2, owner: "legacy", state: "frozen" },
      "frozen while Timekeeping is the outgoing owner" => { generation: 1, owner: "timekeeping", state: "frozen" },
      "frozen while the prepared application is the outgoing owner" => { generation: 1, owner: "monolith", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and compares nothing" do
        freeze_handoff!
        load!
        Ownership.current.update!(**ownership)

        expect { reconcile! }.to raise_error(described_class::OutOfStep, /reconcile expects .*nothing changed/)
      end
    end

    it "refuses on a database where no handoff has run" do
      expect { reconcile! }.to raise_error(described_class::OutOfStep, /reconcile expects generation 1 in state frozen/)
    end
  end

  describe "a checkpoint Timekeeping holds exactly" do
    before do
      freeze_handoff!
      load!
    end

    it "reconciles every entry and reservation of both tenants" do
      expect(reconcile!).to eq(described_class::Reconciled.new(entries: 6, reservations: 3))
    end

    it "reconciles the checkpoint as the handoff tool carries it, through JSON" do
      carried = JSON.parse(JSON.generate(entries))

      expect(carried.pluck("duration")).to eq([0.1, 479.99999, 90.7, 90.7, 90.7, 90.7])
      expect(reconcile!(entries: carried)).to eq(described_class::Reconciled.new(entries: 6, reservations: 3))
    end

    it "writes nothing, and leaves the record frozen for the fence to flip" do
      before = held_rows

      reconcile!

      expect(held_rows).to eq(before)
      expect(Ownership.current.summary).to eq("generation 1, owner legacy, state frozen")
    end

    it "reconciles an empty checkpoint against an empty Timekeeping" do
      [OutboxSnapshot, Reservation, Entry].each(&:delete_all)

      expect(reconcile!(entries: [], reservations: [])).to eq(described_class::Reconciled.new(entries: 0, reservations: 0))
    end
  end

  describe "an unexplained difference (§10.4: it aborts the handoff)" do
    before do
      freeze_handoff!
      load!
    end

    def drop_entry!(id)
      Reservation.where(entry_id: id).delete_all
      OutboxSnapshot.where(entry_id: id).delete_all
      Entry.where(id:).delete_all
    end

    def change_reservation!(entry_id, **changes)
      Reservation.where(entry_id:).update_all(changes)
    end

    {
      "an entry the checkpoint carries and Timekeeping does not hold" => [
        -> { drop_entry!(104) }, {}, { entry_missing: [104] }
      ],
      "an entry Timekeeping holds and the checkpoint does not carry" => [
        -> { }, { entries: -> { entries - [discarded] } }, { entry_unexpected: [104] }
      ],
      "a duration off by the last bit" => [
        -> { Entry.where(id: 205).update_all(duration: 90.70000000000002) }, {}, { entry_differs: [205] }
      ],
      "a timestamp off by a microsecond" => [
        -> { Entry.where(id: 230).update_all(updated_at: Time.utc(2026, 11, 3, 17, 45, 1, 654_322)) }, {}, { entry_differs: [230] }
      ],
      "an entry at another version" => [
        -> { Entry.where(id: 102).update_all(version: 2) }, {}, { entry_differs: [102] }
      ],
      "an entry of another tenant (§6.3)" => [
        -> { Entry.where(id: 205).update_all(company_id: 1) }, {}, { entry_differs: [205] }
      ],
      "a source metadata key missing" => [
        -> { Entry.where(id: 230).update_all(source_metadata: {}) }, {}, { entry_differs: [230] }
      ],
      "a reservation held by another invoice" => [
        -> { change_reservation!(103, invoice_id: 504) }, {}, { reservations_differ: [103] }
      ],
      "a reservation of another tenant (§6.3)" => [
        -> { change_reservation!(102, company_id: 2) }, {}, { reservations_differ: [102] }
      ],
      "a reservation with another disposition" => [
        -> { change_reservation!(101, disposition: "retained") }, {}, { reservations_differ: [101] }
      ],
      "a reservation with the edit lock, so the derived locked differs too" => [
        -> { change_reservation!(102, edit_lock: true) }, {}, { entry_differs: [102], reservations_differ: [102] }
      ],
      "a reservation Timekeeping does not hold" => [
        -> { Reservation.where(entry_id: 102).delete_all }, {}, { reservations_differ: [102] }
      ],
      "a reservation the checkpoint does not carry" => [
        -> { Reservation.create!(committed(released, invoice_id: 601, edit_lock: false).then { |value| Reservation.row_for(value) }) },
        {}, { reservations_differ: [205] }
      ],
      "a reservation operation the legacy owner never registered" => [
        -> {
          ReservationOperation.create!(invoice_id: 701, operation_id: "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6", state: "aborted")
        },
        {}, { reservation_operation_unexpected: ["701/8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6"] }
      ],
      "an idempotency receipt the legacy owner never stored" => [
        -> { IdempotencyReceipt.create!(company_id: 2, key: "web-42", request_digest: "x", status: 201, response: {}) },
        {}, { idempotency_receipt_unexpected: ["2/web-42"] }
      ]
    }.each do |name, (tamper, carried, lists)|
      it "lists #{name}, and writes nothing" do
        instance_exec(&tamper)
        before = held_rows
        checkpoint = carried.transform_values { |value| instance_exec(&value) }

        expect(reconcile_differences(**checkpoint)).to eq(lists)
        expect(held_rows).to eq(before)
      end
    end

    it "lists every difference it finds, both tenants at once" do
      drop_entry!(104)
      Entry.where(id: 230).update_all(note: "changed")
      change_reservation!(101, invoice_id: 599)

      expect(reconcile_differences).to eq(entry_missing: [104], entry_differs: [230], reservations_differ: [101])
    end

    it "names each list and what it found in its message" do
      drop_entry!(104)

      expect { reconcile! }.to raise_error(described_class::Differs, "Timekeeping checkpoint reconcile: entry_missing 104; abort the handoff")
    end
  end
end
