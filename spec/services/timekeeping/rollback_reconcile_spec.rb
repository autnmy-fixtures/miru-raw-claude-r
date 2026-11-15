# frozen_string_literal: true

require "rails_helper"

# Step 6 of the rollback on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4
# "Reconciliation"): the checkpoint taken out of Timekeeping, against the
# prepared application's tables it was loaded into, the projection, kept
# invoices' lines and links, and money, each exact, on two tenants.
#
# The billing state is reached through the behaviour that produces it today,
# as the first cutover's reconcile spec reaches it. What Timekeeping holds
# after that cutover is its checkpoint (the legacy checkpoint's entries and
# reservations, delivered into the projection) plus the audit rows and
# receipts its writes left. The rollback then freezes under the `timekeeping`
# owner at generation 2, and Timekeeping::CheckpointLoad loads it. A
# difference is made afterwards with relation-level writes, which no fence or
# callback sees, or by handing the reconcile another checkpoint than the one
# loaded.
RSpec.describe Timekeeping::RollbackReconcile, type: :model do
  include_context "with two Timekeeping tenants"

  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:generation) { 2 }
  let(:created_at) { "2026-11-02T09:15:30.123456Z" }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 90.7) }
  let!(:grouped_entries) { [unbilled_entry(tenant_a, duration: 0.1), unbilled_entry(tenant_a, duration: 479.99999)] }
  let!(:retained_entry) { unbilled_entry(tenant_a) }
  let!(:linked_entry) { unbilled_entry(tenant_b) }
  let!(:discarded_entry) { unbilled_entry(tenant_a).tap(&:discard!) }

  # A direct and a grouped draft (L1), a sent invoice discarded after a draft
  # save (L3, retained), and tenant B's invoice created sent, whose entry no
  # draft save ever locked (an unlocked link with its recorded disposition).
  let!(:draft) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, draft_entry)
      grouped_line(invoice, grouped_entries)
      invoice.reload.save!
    end
  end
  let!(:retained_invoice) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, retained_entry)
      invoice.reload.save!
      invoice.update!(status: :sent)
      invoice.discard!
    end
  end
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  # The "before" of the money check, taken once every billing write is done,
  # as the handoff tool takes it right after close.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  let(:committed_operation) { "3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f" }
  let(:aborted_operation) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }

  def audit(id:, entry:, **fields)
    {
      "id" => id, "entry_id" => entry.id, "company_id" => entry.project.client.company_id, "version" => 1,
      "action" => "create", "actor" => "user:#{entry.user_id}", "agent_id" => nil, "writer" => "web",
      "request_id" => "req-#{id}", "audited_changes" => { "duration" => 0.1, "note" => nil }, "created_at" => created_at
    }.merge(fields.transform_keys(&:to_s))
  end

  # What Timekeeping holds when the rollback freezes: what the first cutover
  # carried, delivered into the projection, and the audit rows and receipts
  # of its writes since, on both tenants.
  let(:checkpoint) do
    set_timekeeping_ownership!(generation: 1, owner: "legacy", state: "frozen")
    legacy = Timekeeping::LegacyCheckpoint.take(generation: 1, unlocked_link_invoice_ids: [unlocked_link_invoice.id])
    deliver!(legacy.entries)

    Timekeeping::HandoffClient::TakenCheckpoint.new(
      generation:,
      entries: legacy.entries,
      reservations: legacy.reservations,
      entry_audits: [
        audit(id: 9, entry: draft_entry),
        audit(id: 14, entry: linked_entry, version: 2, action: "update", audited_changes: { "note" => [nil, "Proofing"] })
      ],
      reservation_operations: [
        { "invoice_id" => draft.id, "operation_id" => committed_operation, "company_id" => tenant_a.company.id, "kind" => "save",
          "invoice_state" => "draft", "entry_ids" => [draft_entry.id, *grouped_entries.map(&:id)], "state" => "committed",
          "created_at" => created_at, "updated_at" => "2026-11-02T09:15:31.000001Z" },
        { "invoice_id" => draft.id + 1000, "operation_id" => aborted_operation, "company_id" => nil, "kind" => nil,
          "invoice_state" => nil, "entry_ids" => [], "state" => "aborted", "created_at" => created_at, "updated_at" => created_at }
      ],
      idempotency_receipts: [
        { "company_id" => tenant_a.company.id, "key" => "web-1", "request_digest" => "d1", "status" => 201,
          "response" => { "entry" => { "id" => draft_entry.id, "duration" => 90.7 } }, "created_at" => created_at },
        { "company_id" => tenant_b.company.id, "key" => "web-1", "request_digest" => "d2", "status" => 200,
          "response" => { "discarded_ids" => [] }, "created_at" => created_at }
      ]
    )
  end

  # The relay delivering one snapshot per entry, at its version.
  def deliver!(entries)
    snapshots = entries.map do |entry|
      relay.snapshot(
        entry_id: entry.fetch("id"), version: entry.fetch("version"), company_id: entry.fetch("company_id"),
        **entry.except("id", "version", "company_id").symbolize_keys
      )
    end
    expect(Timekeeping::ProjectionConsumer.process(snapshots)).to be_a(Timekeeping::ProjectionConsumer::Applied)
  end

  def freeze_rollback!(owner: "timekeeping", state: "frozen", at: generation)
    set_timekeeping_ownership!(generation: at, owner:, state:)
  end

  # The rollback frozen, and the checkpoint loaded into the prepared tables.
  def load!
    carried = checkpoint
    freeze_rollback!
    Timekeeping::CheckpointLoad.call(carried)
  end

  def reconcile(carried = checkpoint, financial_snapshot: money_before)
    described_class.call(carried, financial_snapshot:)
  end

  # The lists a reconcile that must fail names.
  def differs(carried = checkpoint, **options)
    lists = nil
    expect { reconcile(carried, **options) }.to raise_error(described_class::Differs) { |error| lists = error.lists }
    lists
  end

  def carrying(**parts) = checkpoint.with(**parts)

  def without(reservations, target)
    reservations.reject { |reservation| reservation.entry_id == target.id }
  end

  # The load moves the prepared application's entry and audit sequences,
  # which no fixture transaction rolls back; put back what it found.
  def sequenced = [Timekeeping::Entry, Timekeeping::EntryAudit]

  def sequence_state(model)
    model.connection.select_rows("SELECT last_value, is_called FROM #{model.connection.quote_table_name(model.sequence_name)}").first
  end

  around do |example|
    found = sequenced.index_with { |model| sequence_state(model) }
    example.run
  ensure
    found&.each do |model, (value, called)|
      model.connection.select_value("SELECT setval(#{model.connection.quote(model.sequence_name)}, #{Integer(value)}, #{called})")
    end
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { owner: "timekeeping", state: "open" },
      "admission closed, not frozen" => { owner: "timekeeping", state: "closed" },
      "frozen at another generation" => { owner: "timekeeping", state: "frozen", at: 3 },
      "frozen under the legacy owner (the first cutover)" => { owner: "legacy", state: "frozen" },
      "frozen under the monolith owner (the re-cutover)" => { owner: "monolith", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}" do
        load!
        freeze_rollback!(**ownership)

        expect { reconcile }.to raise_error(described_class::OutOfStep, /reconcile expects .*nothing changed/)
      end
    end

    it "refuses where no handoff has run" do
      carried = checkpoint
      set_timekeeping_ownership!(generation: 0, owner: "legacy", state: "open")

      expect { reconcile(carried) }.to raise_error(described_class::OutOfStep, /generation 0, owner legacy, state open/)
    end

    it "takes the record FOR SHARE before it reads any table it reconciles" do
      load!
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

      reconcile

      ActiveSupport::Notifications.unsubscribe(subscriber)
      lock = statements.index { |sql| sql.include?("timekeeping_ownerships") && sql.include?("FOR SHARE") }
      first_read = statements.index { |sql| Timekeeping::CheckpointLoad::TABLES.any? { |model| sql.include?(%("#{model.table_name}")) } }
      expect(lock).to be < first_read
    end
  end

  describe "a checkpoint that agrees" do
    before { load! }

    it "reconciles every entry, reservation, audit row and receipt of both tenants" do
      expect(reconcile).to eq(
        described_class::Reconciled.new(
          entries: TimesheetEntry.count, reservations: 5, entry_audits: 2, reservation_operations: 2, idempotency_receipts: 2
        )
      )
      expect(checkpoint.reservations.map(&:disposition).tally).to eq(active: 4, retained: 1)
      expect(checkpoint.entries.map { |entry| entry.fetch("company_id") }.uniq).to contain_exactly(tenant_a.company.id, tenant_b.company.id)
    end

    it "reconciles the checkpoint and the financial snapshot as the handoff tool carries them, through JSON" do
      through_json = ->(rows) { JSON.parse(JSON.generate(rows)) }
      carried = carrying(
        entries: through_json.call(checkpoint.entries), entry_audits: through_json.call(checkpoint.entry_audits),
        reservation_operations: through_json.call(checkpoint.reservation_operations),
        idempotency_receipts: through_json.call(checkpoint.idempotency_receipts)
      )

      expect(carried.entries.map { |entry| entry.fetch("duration") }).to include(90.7, 0.1, 479.99999)
      expect(reconcile(carried, financial_snapshot: through_json.call(money_before))).to be_a(described_class::Reconciled)
    end

    it "writes nothing, and leaves the handoff frozen" do
      tables = %w[
        timesheet_entries invoices invoice_line_items invoice_line_item_time_entries invoice_taxes timekeeping_ownerships
        timekeeping_entries timekeeping_reservations timekeeping_entry_audits timekeeping_reservation_operations
        timekeeping_idempotency_receipts timekeeping_outbox_snapshots
      ]
      rows = -> { tables.index_with { |table| ActiveRecord::Base.connection.select_rows("SELECT * FROM #{table}").sort_by(&:inspect) } }

      expect { reconcile }.not_to change(&rows)
      expect(Timekeeping::Ownership.current).to have_attributes(generation: 2, owner: "timekeeping", state: "frozen")
    end
  end

  describe "the prepared application's entries" do
    before { load! }

    it "lists every entry while nothing has been loaded" do
      Timekeeping::EntryAudit.delete_all
      Timekeeping::Entry.delete_all

      expect(differs).to eq(entry_missing: checkpoint.entries.map { |entry| entry.fetch("id") }.sort, entry_audit_missing: [9, 14])
    end

    it "lists an entry the checkpoint carries that the prepared table does not hold" do
      Timekeeping::Entry.where(id: discarded_entry.id).delete_all

      expect(differs).to eq(entry_missing: [discarded_entry.id])
    end

    it "lists an entry the prepared table holds that the checkpoint does not carry" do
      Timekeeping::Entry.insert_all!([Timekeeping::Entry.row_for(checkpoint.entries.last.merge("id" => 999_001))], record_timestamps: false)

      expect(differs).to eq(entry_unexpected: [999_001])
    end

    it "lists a duration off by the last bit" do
      Timekeeping::Entry.where(id: draft_entry.id).update_all(duration: 90.7.next_float)

      expect(differs).to eq(entry_differs: [draft_entry.id])
    end

    it "lists a timestamp off by one microsecond" do
      Timekeeping::Entry.where(id: discarded_entry.id).update_all(["updated_at = updated_at + interval '1 microsecond'"])

      expect(differs).to eq(entry_differs: [discarded_entry.id])
    end

    it "lists an entry at another version" do
      Timekeeping::Entry.where(id: linked_entry.id).update_all("version = version + 1")

      expect(differs).to eq(entry_differs: [linked_entry.id])
    end
  end

  describe "the prepared application's reservations" do
    before { load! }

    it "lists an entry whose edit lock the prepared table lost, and the `locked` it derives" do
      Timekeeping::Reservation.where(entry_id: draft_entry.id).update_all(edit_lock: false)

      expect(differs).to eq(entry_differs: [draft_entry.id], reservations_differ: [draft_entry.id])
    end

    it "lists a destroyed or discarded non-draft's retained reservation the prepared table lost (§7.3)" do
      Timekeeping::Reservation.where(entry_id: retained_entry.id).delete_all

      expect(differs).to eq(entry_differs: [retained_entry.id], reservations_differ: [retained_entry.id])
    end

    it "lists a reservation held under another owner" do
      Timekeeping::Reservation.where(entry_id: linked_entry.id).update_all(invoice_id: draft.id)

      expect(differs).to eq(reservations_differ: [linked_entry.id])
    end

    it "lists a reservation the prepared table holds that the checkpoint does not carry" do
      Timekeeping::Reservation.insert_all!([
        Timekeeping::Reservation.row_for(checkpoint.reservations.first.with(entry_id: discarded_entry.id, edit_lock: false))
      ])

      expect(differs).to eq(reservations_differ: [discarded_entry.id])
    end
  end

  describe "the receipts" do
    before { load! }

    it "lists an audit row that differs, one missing and one unexpected" do
      Timekeeping::EntryAudit.where(id: 9).update_all(audited_changes: { "duration" => 0.1.next_float, "note" => nil })
      Timekeeping::EntryAudit.where(id: 14).delete_all
      Timekeeping::EntryAudit.insert_all!([audit(id: 15, entry: draft_entry)], record_timestamps: false)

      expect(differs).to eq(entry_audit_differs: [9], entry_audit_missing: [14], entry_audit_unexpected: [15])
    end

    it "lists an operation receipt that differs by its outcome" do
      Timekeeping::ReservationOperation.where(operation_id: committed_operation).update_all(state: "aborted")

      expect(differs).to eq(reservation_operation_differs: ["#{draft.id}/#{committed_operation}"])
    end

    it "lists the no-op abort the prepared table lost, so a late abort would not answer its stored receipt" do
      Timekeeping::ReservationOperation.where(operation_id: aborted_operation).delete_all

      expect(differs).to eq(reservation_operation_missing: ["#{draft.id + 1000}/#{aborted_operation}"])
    end

    it "lists an idempotency receipt whose stored answer differs" do
      Timekeeping::IdempotencyReceipt.where(company_id: tenant_b.company.id).update_all(status: 201)

      expect(differs).to eq(idempotency_receipt_differs: ["#{tenant_b.company.id}/web-1"])
    end

    it "lists an idempotency receipt held under the other tenant" do
      Timekeeping::IdempotencyReceipt.where(company_id: tenant_a.company.id).update_all(key: "web-2")

      expect(differs).to eq(
        idempotency_receipt_missing: ["#{tenant_a.company.id}/web-1"], idempotency_receipt_unexpected: ["#{tenant_a.company.id}/web-2"]
      )
    end
  end

  describe "this application's own tables" do
    before { load! }

    it "lists an entry whose last snapshot the projection has not taken" do
      TimesheetEntry.where(id: grouped_entries.first.id).update_all(locked: false)

      expect(differs).to eq(projection_differs: [grouped_entries.first.id])
    end

    it "lists an entry the projection does not hold" do
      TimesheetEntry.where(id: discarded_entry.id).delete_all

      expect(differs).to eq(projection_missing: [discarded_entry.id])
    end

    it "lists a kept invoice's reference with no active reservation in the checkpoint, and the prepared table that holds it" do
      carried = carrying(reservations: without(checkpoint.reservations, grouped_entries.last))

      expect(differs(carried)).to eq(reference_without_reservation: [grouped_entries.last.id], reservations_differ: [grouped_entries.last.id])
    end

    it "lists an invoice value that changed" do
      Invoice.where(id: draft.id).update_all(amount: draft.amount + 0.01)

      expect(differs).to eq(money_differs: ["invoices/#{draft.id}/amount"])
    end
  end

  it "lists every difference at once, across both tenants, and names them in its message" do
    load!
    Timekeeping::Entry.where(id: bystander_entry.id).update_all(duration: 1.5)
    Timekeeping::IdempotencyReceipt.where(company_id: tenant_b.company.id).delete_all
    Invoice.where(id: unlocked_link_invoice.id).update_all(discount: 1)

    expect { reconcile }.to raise_error(described_class::Differs) { |error|
      expect(error.lists).to eq(
        entry_differs: [bystander_entry.id],
        idempotency_receipt_missing: ["#{tenant_b.company.id}/web-1"],
        money_differs: ["invoice_pdf_totals/#{unlocked_link_invoice.id}/total", "invoices/#{unlocked_link_invoice.id}/discount"]
      )
      expect(error.message).to start_with("Timekeeping checkpoint reconcile: entry_differs #{bystander_entry.id}; ")
      expect(error.message).to end_with("; abort the handoff")
    }
  end

  describe "the checkpoint as the handoff tool takes it out of Timekeeping" do
    let!(:fake) { TimekeepingContracts::FakeHandoff.new(generation: 1, owner: "timekeeping").install! }
    let(:client) { Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

    def wire(held)
      held.to_h.transform_keys(&:to_s).merge("state" => held.state.to_s, "disposition" => held.disposition.to_s)
    end

    it "reconciles the client's TakenCheckpoint, loaded as it came over the wire" do
      held = checkpoint
      fake.hold!(**held.to_h.except(:generation).merge(reservations: held.reservations.map { |reservation| wire(reservation) }))
      client.run_step(:close, generation: 1)
      client.run_step(:freeze, generation: 2)
      freeze_rollback!

      taken = client.take_checkpoint(generation: 2)
      Timekeeping::CheckpointLoad.call(taken)

      expect(reconcile(taken)).to be_a(described_class::Reconciled)
    end
  end
end
