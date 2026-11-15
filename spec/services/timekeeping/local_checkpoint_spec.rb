# frozen_string_literal: true

require "rails_helper"

# Step 4 of the re-cutover on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 4): the
# frozen checkpoint taken from the prepared application, the `monolith`
# owner, as the outgoing owner, holding every entry, every reservation, the
# entry audit rows, the terminal invoice-operation receipts and the entry
# API's idempotency receipts, in the forms the rollback's take carries them.
RSpec.describe Timekeeping::LocalCheckpoint, type: :model do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  # Cut over at 1, rolled back at 2; the re-cutover's close raised it to 3.
  let(:generation) { 3 }

  let(:created_at) { Time.utc(2026, 11, 2, 9, 15, 30, 123_456) }
  let(:updated_at) { Time.utc(2026, 11, 3, 17, 45, 1, 654_321) }

  def freeze_handoff!(generation: self.generation, owner: "monolith", state: "frozen")
    set_timekeeping_ownership!(generation:, owner:, state:)
  end

  def take!(generation: self.generation) = described_class.take(generation:)

  # Everything the prepared application holds, row by row, and the
  # projection, to show the take wrote nothing.
  def held_rows
    [
      Timekeeping::Ownership, Timekeeping::Entry, Timekeeping::Reservation, Timekeeping::OutboxSnapshot,
      Timekeeping::EntryAudit, Timekeeping::IdempotencyReceipt, Timekeeping::ReservationOperation, TimesheetEntry
    ].map { |model| model.order(:id).map(&:attributes) }
  end

  def entry!(company_id:, **attributes)
    Timekeeping::Entry.create!(
      {
        company_id:, project_id: 10 + company_id, user_id: 7, duration: 90.7, work_date: Date.new(2026, 11, 2),
        bill_status: "unbilled", created_at:, updated_at:
      }.merge(attributes)
    )
  end

  def reservation!(entry, invoice_id:, state: "committed", disposition: "active", edit_lock: true, operation_id: nil)
    entry.reservations.create!(invoice_id:, company_id: entry.company_id, state:, disposition:, edit_lock:, operation_id:)
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
    Timekeeping::ReservationOperation.create!(
      { invoice_id:, operation_id: SecureRandom.uuid, state:, created_at:, updated_at: }.merge(attributes)
    )
  end

  # The checkpoint as the wire would carry it: reservations as the
  # contract's objects, every other part already JSON.
  def wire(checkpoint)
    checkpoint.to_h.transform_keys(&:to_s).merge(
      "reservations" => checkpoint.reservations.map do |reservation|
        reservation.to_h.transform_keys(&:to_s).merge("state" => reservation.state.to_s, "disposition" => reservation.disposition.to_s)
      end
    )
  end

  # Two tenants, as the prepared application holds them after a rollback and
  # some writes under the `monolith` owner:
  #
  # Fork & Leaf: an entry on a kept draft (active, edit lock) at version 3,
  # one on a non-draft with no lock, one held by a destroyed non-draft
  # (retained, edit lock, §7.3), and a discarded entry with no reservation.
  # Copper Kettle: an agent's entry pending review, on a kept draft, whose
  # metadata holds a null inside an array.
  let!(:on_draft) { entry!(company_id: fork_and_leaf, id: 101, version: 3, duration: 0.1, note: "Kitchen prep") }
  let!(:unlocked_link) { entry!(company_id: fork_and_leaf, id: 102, duration: 479.99999, note: nil) }
  let!(:retained) { entry!(company_id: fork_and_leaf, id: 103, version: 2, bill_status: "billed") }
  let!(:discarded) { entry!(company_id: fork_and_leaf, id: 104, discarded_at: Time.utc(2026, 11, 4, 8, 0, 0, 1)) }
  let!(:agent_entry) do
    entry!(
      company_id: copper_kettle, id: 230, version: 5, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru" }, proof_url: "https://example.test/run/9",
      proof_metadata: { "commits" => 3, "verified" => false, "tags" => [nil, "a"] },
      external_run_id: "run-9", external_session_id: "session-2"
    )
  end

  let(:draft_operation) { "0f8e2c1a-5b4d-4e3f-9a2b-1c0d9e8f7a6b" }
  let(:noop_abort) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }

  before do
    # Rows are written out of the order the checkpoint carries them in, so
    # that order is the take's, not the table's.
    reservation!(agent_entry, invoice_id: 601)
    reservation!(retained, invoice_id: 503, disposition: "retained")
    reservation!(on_draft, invoice_id: 501)
    reservation!(unlocked_link, invoice_id: 502, edit_lock: false)

    audit!(agent_entry, id: 14, action: "create", version: 1, actor: "agent:4", agent_id: 4, writer: "agent", audited_changes: {})
    audit!(on_draft, id: 10, version: 2)
    audit!(on_draft, id: 9, action: "create", version: 1, audited_changes: { "duration" => 0.1 })

    # An abort of an operation never prepared: the no-op receipt (§9.3).
    operation!(invoice_id: 701, operation_id: noop_abort, state: "aborted")

    operation!(
      invoice_id: 501, operation_id: draft_operation, state: "committed", company_id: fork_and_leaf, kind: "save",
      invoice_state: "draft", entry_ids: [101]
    )
    operation!(
      invoice_id: 601, state: "committed", company_id: copper_kettle, kind: "save", invoice_state: "draft", entry_ids: [230]
    )

    Timekeeping::IdempotencyReceipt.create!(
      company_id: copper_kettle, key: "web-1", request_digest: "d2", status: 200, response: { "entry" => nil }, created_at:
    )
    Timekeeping::IdempotencyReceipt.create!(
      company_id: fork_and_leaf, key: "web-1", request_digest: "d1", status: 201,
      response: { "entry" => { "id" => 101, "duration" => 0.1 } }, created_at:
    )
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { owner: "monolith", state: "open" },
      "admission closed, not yet frozen (settle may still be running)" => { owner: "monolith", state: "closed" },
      "frozen at another generation" => { generation: 4, owner: "monolith", state: "frozen" },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy", state: "frozen" },
      "frozen while Timekeeping is the outgoing owner (a rollback)" => { owner: "timekeeping", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and takes nothing" do
        freeze_handoff!(**ownership)
        before = held_rows

        expect { take! }.to raise_error(described_class::OutOfStep, /checkpoint expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end

    it "refuses on a database where no handoff has run" do
      expect { take! }.to raise_error(described_class::OutOfStep, /checkpoint expects generation 3 in state frozen/)
    end

    it "holds the record FOR SHARE before it reads anything else" do
      freeze_handoff!
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end

      begin
        take!
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      first_read = statements.index { |sql| sql.include?('FROM "timekeeping_ownerships"') && sql.include?("FOR SHARE") }
      expect(first_read).not_to be_nil
      expect(statements.first(first_read))
        .to all(satisfy { |sql| !sql.match?(/FROM "timekeeping_(entries|reservations|entry_audits|reservation_operations|idempotency_receipts)"/) })
    end
  end

  describe "a settled, frozen handoff" do
    before { freeze_handoff! }

    let(:checkpoint) { take! }

    it "names the generation it was taken at and the highest entry and audit ids (§10.3)" do
      expect(checkpoint.generation).to eq(generation)
      expect(checkpoint.highest_entry_id).to eq(230)
      expect(checkpoint.highest_entry_audit_id).to eq(14)
    end

    it "is the contract's taken checkpoint, so Timekeeping's load reads the rollback's shape" do
      expect(Timekeeping::Contracts.errors(:handoff_api, "#/$defs/taken_checkpoint", wire(checkpoint))).to eq([])
    end

    it "carries every entry of both tenants, discarded ones included, as the contract's full entry" do
      expect(checkpoint.entries.pluck("id")).to eq([101, 102, 103, 104, 230])
      expect(checkpoint.entries.pluck("company_id")).to eq([1, 1, 1, 1, 2])
      checkpoint.entries.each { |entry| expect(Timekeeping::Contracts.errors(:common, "#/$defs/entry", entry)).to eq([]) }
      expect(checkpoint.entries).to eq(Timekeeping::Entry.includes(:reservations).order(:id).map(&:to_contract))
    end

    it "keeps the versions the prepared application holds: the projection already has them, so nothing is renumbered" do
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
        "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z",
        "work_date" => "2026-11-02", "note" => "Kitchen prep"
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
      expect(checkpoint.entry_audits).to eq(
        Timekeeping::EntryAudit.order(:id).map do |audit|
          {
            "id" => audit.id, "entry_id" => audit.entry_id, "company_id" => audit.company_id, "version" => audit.version,
            "action" => audit.action, "actor" => audit.actor, "agent_id" => audit.agent_id, "writer" => audit.writer,
            "request_id" => audit.request_id, "audited_changes" => audit.audited_changes,
            "created_at" => "2026-11-02T09:15:30.123456Z"
          }
        end
      )
      expect(checkpoint.entry_audits.pluck("id", "entry_id", "version", "action"))
        .to eq([[9, 101, 1, "create"], [10, 101, 2, "update"], [14, 230, 1, "create"]])
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

    it "carries the entry API's idempotency receipts of both tenants, so a retry after the re-cutover replays" do
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

    context "with sequences put back afterwards" do
      # A sequence is not transactional: the load below moves the entry and
      # audit sequences, and the fixture transaction would not put them back.
      def sequence_state(model)
        model.connection.select_rows("SELECT last_value, is_called FROM #{model.connection.quote_table_name(model.sequence_name)}").first
      end

      around do |example|
        found = [Timekeeping::Entry, Timekeeping::EntryAudit].index_with { |model| sequence_state(model) }
        example.run
      ensure
        found&.each do |model, (value, called)|
          model.connection.select_value(
            "SELECT setval(#{model.connection.quote(model.sequence_name)}, #{Integer(value)}, #{called ? 'true' : 'false'})"
          )
        end
      end

      it "is what the rollback's load takes in: loaded back and taken again, every part is unchanged (§13 item 3)" do
        taken = checkpoint
        [
          Timekeeping::Reservation, Timekeeping::EntryAudit, Timekeeping::OutboxSnapshot, Timekeeping::Entry,
          Timekeeping::ReservationOperation, Timekeeping::IdempotencyReceipt
        ].each(&:delete_all)

        # The same parts, loaded by the rollback's load as if Timekeeping had
        # carried them at the generation before.
        freeze_handoff!(generation: generation - 1, owner: "timekeeping")
        Timekeeping::CheckpointLoad.call(taken.with(generation: generation - 1))
        freeze_handoff!

        expect(take!).to eq(taken)
      end
    end

    it "writes nothing, and leaves the record frozen for the fence to flip" do
      before = held_rows

      checkpoint

      expect(held_rows).to eq(before)
      expect(Timekeeping::Ownership.current.summary).to eq("generation 3, owner monolith, state frozen")
    end

    it "takes an empty checkpoint from a prepared application that holds nothing" do
      [
        Timekeeping::Reservation, Timekeeping::EntryAudit, Timekeeping::OutboxSnapshot, Timekeeping::Entry,
        Timekeeping::ReservationOperation, Timekeeping::IdempotencyReceipt
      ].each(&:delete_all)

      expect(checkpoint).to eq(
        described_class::Checkpoint.new(
          generation:, entries: [], reservations: [], entry_audits: [], reservation_operations: [], idempotency_receipts: []
        )
      )
      expect(checkpoint.highest_entry_id).to be_nil
      expect(checkpoint.highest_entry_audit_id).to be_nil
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
      reservation!(provisional, invoice_id: 801, state: "provisional", operation_id: pending.operation_id)
      before = held_rows

      expect(unsettled_lists).to eq(provisional_reservation: [231], unresolved_operation: ["801/#{pending.operation_id}"])
      expect(held_rows).to eq(before)
    end

    it "says why in its message" do
      pending = operation!(invoice_id: 801, state: "prepared", company_id: copper_kettle, kind: "discard", invoice_state: "draft")

      expect { take! }.to raise_error(
        described_class::Unsettled, "Timekeeping checkpoint: unresolved_operation 801/#{pending.operation_id}; settle first, nothing taken"
      )
    end
  end
end
