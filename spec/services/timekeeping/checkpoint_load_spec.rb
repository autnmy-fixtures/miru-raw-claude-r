# frozen_string_literal: true

require "rails_helper"

# The rollback's checkpoint load on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 steps 4 and 5):
# what Timekeeping held, taken out of it frozen, loaded into the prepared
# application's own tables, and the entry and audit sequences set above the
# carried ids (§10.3).
RSpec.describe Timekeeping::CheckpointLoad, type: :model do
  # Timekeeping owned the entries after a cutover at generation 1; the
  # rollback's close raised the generation to 2 and froze there.
  let(:generation) { 2 }
  let(:created_at) { "2026-11-02T09:15:30.123456Z" }

  def entry(id:, company_id:, **fields)
    TimekeepingContracts::ENTRY_DEFAULTS.merge(
      "id" => id, "company_id" => company_id, "version" => 1, "project_id" => 10 + company_id, "user_id" => 7,
      "duration" => 90.7, "work_date" => "2026-11-02",
      "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
    ).merge(fields.transform_keys(&:to_s))
  end

  def reservation(entry_id:, invoice_id:, company_id:, disposition: :active, edit_lock: true, state: :committed, operation_id: nil)
    TimekeepingReservations::Reservation.new(entry_id:, invoice_id:, company_id:, operation_id:, state:, disposition:, edit_lock:)
  end

  def audit(id:, entry_id:, company_id:, **fields)
    {
      "id" => id, "entry_id" => entry_id, "company_id" => company_id, "version" => 1, "action" => "create",
      "actor" => "user:7", "agent_id" => nil, "writer" => "web", "request_id" => "req-#{id}",
      "audited_changes" => { "duration" => 0.1, "note" => nil }, "created_at" => created_at
    }.merge(fields.transform_keys(&:to_s))
  end

  let(:committed_operation) { "3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f" }
  let(:aborted_operation) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }

  # What Timekeeping holds on two tenants after the cutover and some writes:
  # an entry on a kept draft at version 3, an unlocked link, a destroyed
  # non-draft's retained entry (§7.3), a discarded entry, and an agent's
  # entry whose metadata holds a null inside an array; their audit rows, a
  # committed receipt and the no-op abort (§9.3), and an idempotency receipt
  # per tenant under one key.
  let(:parts) do
    {
      entries: [
        entry(id: 101, company_id: 1, version: 3, locked: true, duration: 0.1, note: "Kitchen prep"),
        entry(id: 102, company_id: 1, duration: 479.99999, note: nil),
        entry(id: 103, company_id: 1, version: 2, locked: true, bill_status: "billed"),
        entry(id: 104, company_id: 1, discarded_at: "2026-11-04T08:00:00.000001Z"),
        entry(id: 230, company_id: 2, version: 5, locked: true, agent_id: 4, source: "mcp", proof_metadata: { "tags" => [nil, "a"] })
      ],
      reservations: [
        reservation(entry_id: 101, invoice_id: 501, company_id: 1),
        reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false),
        reservation(entry_id: 103, invoice_id: 503, company_id: 1, disposition: :retained),
        reservation(entry_id: 230, invoice_id: 601, company_id: 2)
      ],
      entry_audits: [
        audit(id: 9, entry_id: 101, company_id: 1),
        audit(id: 14, entry_id: 230, company_id: 2, version: 5, action: "update", actor: "agent:4", agent_id: 4,
          writer: "agent", audited_changes: { "note" => [nil, "Proofing"] })
      ],
      reservation_operations: [
        { "invoice_id" => 501, "operation_id" => committed_operation, "company_id" => 1, "kind" => "save",
          "invoice_state" => "draft", "entry_ids" => [101], "state" => "committed", "created_at" => created_at,
          "updated_at" => "2026-11-02T09:15:31.000001Z" },
        { "invoice_id" => 701, "operation_id" => aborted_operation, "company_id" => nil, "kind" => nil,
          "invoice_state" => nil, "entry_ids" => [], "state" => "aborted", "created_at" => created_at, "updated_at" => created_at }
      ],
      idempotency_receipts: [
        { "company_id" => 1, "key" => "web-1", "request_digest" => "d1", "status" => 201,
          "response" => { "entry" => { "id" => 101, "duration" => 0.1 } }, "created_at" => created_at },
        { "company_id" => 2, "key" => "web-1", "request_digest" => "d2", "status" => 200,
          "response" => { "discarded_ids" => [] }, "created_at" => created_at }
      ]
    }
  end

  def checkpoint(**overrides)
    Timekeeping::HandoffClient::TakenCheckpoint.new(generation:, **parts.merge(overrides))
  end

  def freeze_rollback!(owner: "timekeeping", state: "frozen", at: generation)
    set_timekeeping_ownership!(generation: at, owner:, state:)
  end

  def timestamp(time) = time&.utc&.iso8601(6)

  def loaded_entries
    Timekeeping::Entry.includes(:reservations).order(:id).map(&:to_contract)
  end

  def loaded_audits
    Timekeeping::EntryAudit.order(:id).map do |row|
      row.attributes.except("created_at").merge("created_at" => timestamp(row.created_at))
    end
  end

  def loaded_operations
    Timekeeping::ReservationOperation.order(:invoice_id).map do |row|
      row.attributes.except("id").merge("created_at" => timestamp(row.created_at), "updated_at" => timestamp(row.updated_at))
    end
  end

  def loaded_idempotency_receipts
    Timekeeping::IdempotencyReceipt.order(:company_id, :key).map do |row|
      row.attributes.except("id").merge("created_at" => timestamp(row.created_at))
    end
  end

  def row_counts
    described_class::TABLES.to_h { |model| [model.table_name, model.count] }
      .merge("timekeeping_outbox_snapshots" => Timekeeping::OutboxSnapshot.count, "timesheet_entries" => TimesheetEntry.count)
  end

  def next_id(model)
    model.connection.select_value("SELECT nextval(#{model.connection.quote(model.sequence_name)})")
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { owner: "timekeeping", state: "open" },
      "admission closed, not frozen (settle may still be running)" => { owner: "timekeeping", state: "closed" },
      "frozen at another generation" => { owner: "timekeeping", state: "frozen", at: 3 },
      "frozen under the legacy owner (the first cutover)" => { owner: "legacy", state: "frozen" },
      "frozen under the monolith owner (the re-cutover)" => { owner: "monolith", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and loads nothing" do
        freeze_rollback!(**ownership)

        expect { described_class.call(checkpoint) }.to raise_error(described_class::OutOfStep, /load expects .*nothing changed/)
        expect(row_counts.values).to all(eq(0))
      end
    end

    it "refuses where no handoff has run" do
      expect { described_class.call(checkpoint) }.to raise_error(described_class::OutOfStep, /generation 0, owner legacy, state open/)
      expect(row_counts.values).to all(eq(0))
    end

    it "takes the record FOR SHARE before it touches any table it loads" do
      freeze_rollback!
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

      described_class.call(checkpoint)

      ActiveSupport::Notifications.unsubscribe(subscriber)
      lock = statements.index { |sql| sql.include?("timekeeping_ownerships") && sql.include?("FOR SHARE") }
      first_read = statements.index { |sql| described_class::TABLES.any? { |model| sql.include?(%("#{model.table_name}")) } }
      expect(lock).to be < first_read
    end

    it "leaves the record frozen for reconcile and flip" do
      freeze_rollback!

      described_class.call(checkpoint)

      expect(Timekeeping::Ownership.current).to have_attributes(generation: 2, owner: "timekeeping", state: "frozen")
    end
  end

  describe "the load" do
    before { freeze_rollback! }

    it "answers what it loaded, part by part" do
      expect(described_class.call(checkpoint)).to eq(
        described_class::Loaded.new(entries: 5, reservations: 4, entry_audits: 2, reservation_operations: 2, idempotency_receipts: 2)
      )
    end

    it "holds every entry of both tenants exactly as carried, `locked` derived from the loaded reservations" do
      described_class.call(checkpoint)

      expect(loaded_entries).to eq(parts[:entries])
      expect(loaded_entries.map { |held| held.values_at("id", "company_id", "version", "duration", "locked") }).to eq(
        [[101, 1, 3, 0.1, true], [102, 1, 1, 479.99999, false], [103, 1, 2, 90.7, true], [104, 1, 1, 90.7, false], [230, 2, 5, 90.7, true]]
      )
      expect(Timekeeping::Entry.find(230).proof_metadata).to eq("tags" => [nil, "a"])
      expect(Timekeeping::Entry.find(102).note).to be_nil
      expect(timestamp(Timekeeping::Entry.find(104).discarded_at)).to eq("2026-11-04T08:00:00.000001Z")
      expect(timestamp(Timekeeping::Entry.find(101).updated_at)).to eq("2026-11-03T17:45:01.654321Z")
    end

    it "holds every reservation, the destroyed non-draft's retained one under its own owner (§7.3)" do
      described_class.call(checkpoint)

      expect(Timekeeping::Reservation.order(:entry_id).map(&:to_value)).to eq(parts[:reservations])
      expect(Timekeeping::Reservation.find_by(entry_id: 103)).to have_attributes(invoice_id: 503, company_id: 1, disposition: "retained")
    end

    it "holds the audit rows by their carried ids" do
      described_class.call(checkpoint)

      expect(loaded_audits).to eq(parts[:entry_audits])
    end

    it "holds both terminal receipts, the no-op abort with its nulls" do
      described_class.call(checkpoint)

      expect(loaded_operations).to eq(parts[:reservation_operations])
    end

    it "holds the idempotency receipts of both tenants under the same key" do
      described_class.call(checkpoint)

      expect(loaded_idempotency_receipts).to eq(parts[:idempotency_receipts])
    end

    it "writes no outbox snapshot and nothing in timesheet_entries: the projection already holds these versions" do
      described_class.call(checkpoint)

      expect(Timekeeping::OutboxSnapshot.count).to eq(0)
      expect(TimesheetEntry.count).to eq(0)
    end

    it "sets the entry and audit sequences above the highest carried ids (§10.3)" do
      described_class.call(checkpoint)

      expect(next_id(Timekeeping::Entry)).to eq(231)
      expect(next_id(Timekeeping::EntryAudit)).to eq(15)
    end

    it "never moves a sequence back" do
      Timekeeping::Entry.connection.execute("SELECT setval('#{Timekeeping::Entry.sequence_name}', 5000)")
      Timekeeping::EntryAudit.connection.execute("SELECT setval('#{Timekeeping::EntryAudit.sequence_name}', 700)")

      described_class.call(checkpoint)

      expect(next_id(Timekeeping::Entry)).to eq(5001)
      expect(next_id(Timekeeping::EntryAudit)).to eq(701)
    end

    it "loads an empty checkpoint as nothing, leaving the sequences where they were" do
      before_entry = Timekeeping::Entry.connection.select_value("SELECT last_value FROM #{Timekeeping::Entry.sequence_name}")
      empty = checkpoint(**parts.transform_values { [] })

      expect(described_class.call(empty)).to eq(described_class::Loaded.new(**described_class::Loaded.members.index_with { 0 }))
      expect(row_counts.values).to all(eq(0))
      expect(Timekeeping::Entry.connection.select_value("SELECT last_value FROM #{Timekeeping::Entry.sequence_name}")).to eq(before_entry)
    end
  end

  describe "what the prepared application can do with what it loaded" do
    before do
      freeze_rollback!
      described_class.call(checkpoint)
    end

    let(:provider) { Timekeeping::LocalReservations.new(entries: Timekeeping::LocalEntries.new) }

    it "answers a replayed commit of an operation Timekeeping committed with its stored receipt, changing nothing" do
      expect { expect(provider.commit(invoice_id: 501, operation_id: committed_operation)).to eq(Timekeeping::LocalReservations::Receipt.new(status: :committed)) }
        .not_to change { [Timekeeping::Reservation.order(:id).map(&:to_value), Timekeeping::Entry.order(:id).pluck(:version)] }
    end

    it "answers a late abort of the no-op abort with its stored receipt" do
      expect(provider.abort(invoice_id: 701, operation_id: aborted_operation)).to eq(Timekeeping::LocalReservations::Receipt.new(status: :aborted))
      expect(Timekeeping::ReservationOperation.where(invoice_id: 701).count).to eq(1)
    end

    it "replays a carried idempotency receipt for its own request digest only" do
      receipt = Timekeeping::IdempotencyReceipt.find_by!(company_id: 1, key: "web-1")

      expect(receipt.replay("d1")).to eq([201, { "entry" => { "id" => 101, "duration" => 0.1 } }])
      expect(receipt.replay("d2")).to be_nil
    end
  end

  describe "a load that already ran" do
    before { freeze_rollback! }

    it "is refused on a second call, changing nothing" do
      described_class.call(checkpoint)

      expect { described_class.call(checkpoint) }.to raise_error(described_class::AlreadyLoaded, /already holds timekeeping_entries/)
      expect(row_counts).to include("timekeeping_entries" => 5, "timekeeping_entry_audits" => 2, "timekeeping_idempotency_receipts" => 2)
    end

    it "is refused when any loaded table holds a row, even with no entry" do
      Timekeeping::IdempotencyReceipt.create!(company_id: 1, key: "web-9", request_digest: "d9", status: 201, response: {})

      expect { described_class.call(checkpoint) }.to raise_error(described_class::AlreadyLoaded, /timekeeping_idempotency_receipts/)
      expect(Timekeeping::Entry.count).to eq(0)
    end
  end

  describe "a checkpoint that does not hold together (§10.4)" do
    before { freeze_rollback! }

    def refused_with(broken)
      expect { described_class.call(broken) }.to raise_error(described_class::Refused) { |refusal|
        yield refusal.lists
        expect(refusal.message).to end_with("nothing loaded")
      }
      expect(row_counts.values).to all(eq(0))
    end

    it "refuses an entry the contract does not describe" do
      broken = checkpoint(entries: parts[:entries].map { |carried| carried["id"] == 102 ? carried.merge("duration" => "a lot") : carried })

      refused_with(broken) { |lists| expect(lists).to eq(not_a_contract_entry: [102]) }
    end

    it "refuses a reservation whose entry is not carried, or is carried under another tenant (§6.3)" do
      broken = checkpoint(reservations: parts[:reservations] + [
        reservation(entry_id: 999, invoice_id: 504, company_id: 1),
        reservation(entry_id: 104, invoice_id: 602, company_id: 2, edit_lock: false)
      ])

      refused_with(broken) { |lists| expect(lists).to eq(reservation_without_its_entry: [999, 104]) }
    end

    it "refuses a provisional reservation: no pending operation crosses the handoff (§10.5 step 2)" do
      provisional = reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false, state: :provisional, operation_id: SecureRandom.uuid)
      broken = checkpoint(reservations: parts[:reservations].map { |held| held.entry_id == 102 ? provisional : held })

      refused_with(broken) { |lists| expect(lists).to eq(provisional_reservation: [102]) }
    end

    it "refuses an entry whose `locked` its reservations do not derive" do
      broken = checkpoint(entries: parts[:entries].map { |carried| carried["id"] == 104 ? carried.merge("locked" => true) : carried })

      refused_with(broken) { |lists| expect(lists).to eq(locked_not_derived: [104]) }
    end

    it "refuses an audit row the contract does not describe" do
      broken = checkpoint(entry_audits: parts[:entry_audits] + [audit(id: 15, entry_id: 101, company_id: 1, action: "discard")])

      refused_with(broken) { |lists| expect(lists).to eq(not_a_contract_audit: [15]) }
    end

    it "refuses an audit row whose entry is not carried, or is carried under another tenant (§6.3)" do
      broken = checkpoint(entry_audits: parts[:entry_audits] + [
        audit(id: 15, entry_id: 999, company_id: 1),
        audit(id: 16, entry_id: 230, company_id: 1)
      ])

      refused_with(broken) { |lists| expect(lists).to eq(audit_without_its_entry: [15, 16]) }
    end

    it "refuses an operation still prepared: only terminal receipts cross" do
      prepared = parts[:reservation_operations].first.merge("invoice_id" => 502, "state" => "prepared")
      broken = checkpoint(reservation_operations: parts[:reservation_operations] + [prepared])

      refused_with(broken) { |lists| expect(lists).to eq(not_a_terminal_receipt: ["502/#{committed_operation}"]) }
    end

    it "refuses an idempotency receipt the contract does not describe" do
      broken = checkpoint(idempotency_receipts: parts[:idempotency_receipts] + [
        parts[:idempotency_receipts].first.merge("key" => "web-2", "status" => 500)
      ])

      refused_with(broken) { |lists| expect(lists).to eq(not_a_contract_idempotency_receipt: ["1/web-2"]) }
    end

    it "lists every failed check at once" do
      broken = checkpoint(
        entries: parts[:entries].map { |carried| carried["id"] == 104 ? carried.merge("locked" => true) : carried },
        entry_audits: parts[:entry_audits] + [audit(id: 15, entry_id: 999, company_id: 1)]
      )

      refused_with(broken) { |lists| expect(lists).to eq(locked_not_derived: [104], audit_without_its_entry: [15]) }
    end
  end

  describe "the checkpoint as the handoff tool takes it out of Timekeeping" do
    let!(:fake) { TimekeepingContracts::FakeHandoff.new(generation: 1, owner: "timekeeping").install! }
    let(:client) { Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

    def wire(held)
      held.to_h.transform_keys(&:to_s).merge("state" => held.state.to_s, "disposition" => held.disposition.to_s)
    end

    it "loads the client's TakenCheckpoint as it came over the wire" do
      fake.hold!(**parts.merge(reservations: parts[:reservations].map { |held| wire(held) }))
      client.run_step(:close, generation: 1)
      client.run_step(:freeze, generation: 2)
      freeze_rollback!

      described_class.call(client.take_checkpoint(generation: 2))

      expect(loaded_entries).to eq(parts[:entries])
      expect(Timekeeping::Reservation.order(:entry_id).map(&:to_value)).to eq(parts[:reservations])
      expect(loaded_audits).to eq(parts[:entry_audits])
      expect(loaded_operations).to eq(parts[:reservation_operations])
      expect(loaded_idempotency_receipts).to eq(parts[:idempotency_receipts])
    end
  end
end
