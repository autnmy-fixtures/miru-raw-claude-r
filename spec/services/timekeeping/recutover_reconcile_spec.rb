# frozen_string_literal: true

require "rails_helper"

# Step 6 of the re-cutover on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4
# "Reconciliation"): the checkpoint Timekeeping::LocalCheckpoint took out of
# the prepared application, against the prepared tables it was taken from,
# the projection, kept invoices' lines and links, and money, each exact, on
# two tenants.
#
# The state is reached the way the journey reaches it. The billing state
# comes from the behaviour that produces it today, as the rollback's
# reconcile spec reaches it; the first cutover's checkpoint is delivered into
# the projection; the rollback freezes under `timekeeping` at generation 2 and
# Timekeeping::CheckpointLoad loads what Timekeeping held. The `monolith`
# owner then takes a write on each tenant through the gateway, and the local
# relay delivers them into the projection. The re-cutover freezes under
# `monolith` at generation 3, and the checkpoint is taken. A difference is
# made afterwards with relation-level writes, which no fence or callback
# sees, or by handing the reconcile another checkpoint than the one taken.
RSpec.describe Timekeeping::RecutoverReconcile, type: :model do
  include_context "with two Timekeeping tenants"

  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:rollback_generation) { 2 }
  let(:generation) { 3 }
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

  # What Timekeeping held when the rollback froze: what the first cutover
  # carried, delivered into the projection, and the audit rows and receipts
  # of its writes since, on both tenants.
  let(:rolled_back) do
    set_timekeeping_ownership!(generation: 1, owner: "legacy", state: "frozen")
    legacy = Timekeeping::LegacyCheckpoint.take(generation: 1, unlocked_link_invoice_ids: [unlocked_link_invoice.id])
    deliver!(legacy.entries)

    Timekeeping::HandoffClient::TakenCheckpoint.new(
      generation: rollback_generation,
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

  # One entry the `monolith` owner accepts after the rollback, through the
  # gateway as a controller hands it over: version 1, with its audit row and
  # its outbox snapshot, and nothing in the projection until the local relay
  # delivers it.
  def log_after_rollback!(tenant, duration:)
    Current.user = tenant.employee
    Current.company = tenant.company
    Timekeeping::Gateway.call(
      Timekeeping::Gateway::CreateEntry.new(
        project: tenant.project, user: tenant.employee, writer: "web",
        attributes: ActionController::Parameters.new(duration: duration.to_s, work_date: "2026-11-09", note: "After rollback").permit!
      )
    )
  ensure
    Current.reset
  end

  # The rollback frozen and loaded, then flipped to the prepared application,
  # which takes a write on each tenant; `relayed` says whether the local
  # relay delivered them before the re-cutover froze (§10.5 step 3).
  def roll_back_and_write!(relayed: true)
    carried = rolled_back
    set_timekeeping_ownership!(generation: rollback_generation, owner: "timekeeping", state: "frozen")
    Timekeeping::CheckpointLoad.call(carried)
    set_timekeeping_ownership!(generation: rollback_generation, owner: "monolith", state: "open")

    written = [log_after_rollback!(tenant_a, duration: 45.5), log_after_rollback!(tenant_b, duration: 0.1)]
    expect(Timekeeping::LocalRelay.new.run).to eq(Timekeeping::LocalRelay::Result.new(delivered: 2, undelivered: 0)) if relayed
    written
  end

  def freeze_recutover!(owner: "monolith", state: "frozen", at: generation)
    set_timekeeping_ownership!(generation: at, owner:, state:)
  end

  # The re-cutover frozen, and the checkpoint taken out of the prepared
  # application.
  def take!(**options)
    roll_back_and_write!(**options)
    freeze_recutover!
    Timekeeping::LocalCheckpoint.take(generation:)
  end

  let(:checkpoint) { take! }

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

  # The rollback's load and the monolith owner's creates move the prepared
  # application's entry and audit sequences, which no fixture transaction
  # rolls back; put back what they found.
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
      "admission still open" => { owner: "monolith", state: "open" },
      "admission closed, not frozen" => { owner: "monolith", state: "closed" },
      "frozen at another generation" => { owner: "monolith", state: "frozen", at: 4 },
      "frozen under the legacy owner (the first cutover)" => { owner: "legacy", state: "frozen" },
      "frozen under the timekeeping owner (a rollback)" => { owner: "timekeeping", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}" do
        carried = checkpoint
        freeze_recutover!(**ownership)

        expect { reconcile(carried) }.to raise_error(described_class::OutOfStep, /reconcile expects .*nothing changed/)
      end
    end

    it "refuses after the flip, when this application no longer owns the entries" do
      carried = checkpoint
      freeze_recutover!(owner: "timekeeping", state: "open")

      expect { reconcile(carried) }.to raise_error(described_class::OutOfStep, /generation 3, owner timekeeping, state open/)
    end

    it "takes the record FOR SHARE before it reads any table it reconciles" do
      carried = checkpoint
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }

      begin
        reconcile(carried)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      lock = statements.index { |sql| sql.include?("timekeeping_ownerships") && sql.include?("FOR SHARE") }
      first_read = statements.index do |sql|
        [*Timekeeping::CheckpointLoad::TABLES, TimesheetEntry, Invoice].any? { |model| sql.include?(%("#{model.table_name}")) }
      end
      expect(lock).to be < first_read
    end
  end

  describe "a checkpoint that agrees" do
    it "reconciles every entry, reservation, audit row and receipt of both tenants, the monolith owner's writes included" do
      written = checkpoint && Timekeeping::Entry.where(note: "After rollback").order(:id).to_a

      expect(reconcile).to eq(
        described_class::Reconciled.new(
          entries: TimesheetEntry.count, reservations: 5, entry_audits: 4, reservation_operations: 2, idempotency_receipts: 2
        )
      )
      expect(written.map(&:company_id)).to eq([tenant_a.company.id, tenant_b.company.id])
      expect(checkpoint.entries.pluck("id")).to include(*written.map(&:id))
      expect(TimesheetEntry.where(id: written.map(&:id)).pluck(:duration)).to contain_exactly(45.5, 0.1)
      expect(checkpoint.reservations.map(&:disposition).tally).to eq(active: 4, retained: 1)
    end

    it "reconciles the checkpoint and the financial snapshot as the handoff tool carries them, through JSON" do
      through_json = ->(rows) { JSON.parse(JSON.generate(rows)) }
      carried = carrying(
        entries: through_json.call(checkpoint.entries), entry_audits: through_json.call(checkpoint.entry_audits),
        reservation_operations: through_json.call(checkpoint.reservation_operations),
        idempotency_receipts: through_json.call(checkpoint.idempotency_receipts)
      )

      expect(carried.entries.map { |entry| entry.fetch("duration") }).to include(90.7, 0.1, 479.99999, 45.5)
      expect(reconcile(carried, financial_snapshot: through_json.call(money_before))).to be_a(described_class::Reconciled)
    end

    it "writes nothing, and leaves the handoff frozen" do
      carried = checkpoint
      tables = %w[
        timesheet_entries invoices invoice_line_items invoice_line_item_time_entries invoice_taxes timekeeping_ownerships
        timekeeping_entries timekeeping_reservations timekeeping_entry_audits timekeeping_reservation_operations
        timekeeping_idempotency_receipts timekeeping_outbox_snapshots
      ]
      rows = -> { tables.index_with { |table| ActiveRecord::Base.connection.select_rows("SELECT * FROM #{table}").sort_by(&:inspect) } }

      expect { reconcile(carried) }.not_to change(&rows)
      expect(Timekeeping::Ownership.current).to have_attributes(generation: 3, owner: "monolith", state: "frozen")
    end
  end

  describe "the prepared application, the checkpoint's source" do
    it "lists an entry the source changed after the take" do
      carried = checkpoint
      Timekeeping::Entry.where(id: draft_entry.id).update_all(duration: 90.7.next_float)

      expect(differs(carried)).to eq(entry_differs: [draft_entry.id])
    end

    it "lists an entry the source holds that the checkpoint does not carry, and the projection that holds it too" do
      entry = checkpoint.entries.find { |carried| carried.fetch("note") == "After rollback" }

      expect(differs(carrying(entries: checkpoint.entries - [entry])))
        .to eq(entry_unexpected: [entry.fetch("id")], projection_unexpected: [entry.fetch("id")])
    end

    it "lists a reservation whose edit lock the source lost, and the `locked` it derives" do
      carried = checkpoint
      Timekeeping::Reservation.where(entry_id: grouped_entries.first.id).update_all(edit_lock: false)

      expect(differs(carried)).to eq(entry_differs: [grouped_entries.first.id], reservations_differ: [grouped_entries.first.id])
    end

    it "lists a destroyed or discarded non-draft's retained reservation the checkpoint does not carry (§7.3)" do
      carried = carrying(reservations: checkpoint.reservations.reject(&:retained?))

      expect(differs(carried)).to eq(reservations_differ: [retained_entry.id])
    end

    it "lists the monolith owner's audit rows the checkpoint does not carry" do
      written = checkpoint.entry_audits.select { |row| row.fetch("audited_changes").fetch("note", nil) == "After rollback" }

      expect(written.size).to eq(2)
      expect(differs(carrying(entry_audits: checkpoint.entry_audits - written))).to eq(entry_audit_unexpected: written.pluck("id").sort)
    end

    it "lists the no-op abort the checkpoint does not carry, so a late abort would not answer its stored receipt" do
      carried = carrying(reservation_operations: checkpoint.reservation_operations.reject { |row| row.fetch("state") == "aborted" })

      expect(differs(carried)).to eq(reservation_operation_unexpected: ["#{draft.id + 1000}/#{aborted_operation}"])
    end

    it "lists an idempotency receipt whose stored answer the checkpoint carries otherwise" do
      receipts = checkpoint.idempotency_receipts.map do |row|
        row.fetch("company_id") == tenant_b.company.id ? row.merge("status" => 201) : row
      end

      expect(differs(carrying(idempotency_receipts: receipts))).to eq(idempotency_receipt_differs: ["#{tenant_b.company.id}/web-1"])
    end
  end

  describe "this application's own tables" do
    it "lists the monolith owner's writes the local relay never delivered: freeze did not drain the outbox (§10.5 step 3)" do
      written = []
      carried = take!(relayed: false).tap { written = Timekeeping::Entry.where(note: "After rollback").order(:id).pluck(:id) }

      expect(Timekeeping::OutboxSnapshot.where(delivered_at: nil).pluck(:entry_id)).to match_array(written)
      expect(differs(carried)).to eq(projection_missing: written)
    end

    it "lists an entry whose last snapshot the projection has not taken" do
      carried = checkpoint
      TimesheetEntry.where(id: grouped_entries.last.id).update_all(locked: false)

      expect(differs(carried)).to eq(projection_differs: [grouped_entries.last.id])
    end

    it "lists a kept invoice's reference with no active reservation in the checkpoint, and the source that holds it" do
      carried = carrying(reservations: checkpoint.reservations.reject { |reservation| reservation.entry_id == linked_entry.id })

      expect(differs(carried)).to eq(reference_without_reservation: [linked_entry.id], reservations_differ: [linked_entry.id])
    end

    it "lists an invoice value that changed" do
      carried = checkpoint
      Invoice.where(id: draft.id).update_all(amount: draft.amount + 0.01)

      expect(differs(carried)).to eq(money_differs: ["invoices/#{draft.id}/amount"])
    end
  end

  it "lists every difference at once, across both tenants, and names them in its message" do
    carried = checkpoint
    Timekeeping::Entry.where(id: bystander_entry.id).update_all(duration: 1.5)
    Timekeeping::IdempotencyReceipt.where(company_id: tenant_b.company.id).delete_all
    Invoice.where(id: unlocked_link_invoice.id).update_all(discount: 1)

    expect { reconcile(carried) }.to raise_error(described_class::Differs) { |error|
      expect(error.lists).to eq(
        entry_differs: [bystander_entry.id],
        idempotency_receipt_missing: ["#{tenant_b.company.id}/web-1"],
        money_differs: ["invoice_pdf_totals/#{unlocked_link_invoice.id}/total", "invoices/#{unlocked_link_invoice.id}/discount"]
      )
      expect(error.message).to start_with("Timekeeping checkpoint reconcile: entry_differs #{bystander_entry.id}; ")
      expect(error.message).to end_with("; abort the handoff")
    }
  end

  describe "one checkpoint, reconciled on both sides" do
    let(:client) { Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

    def wire(held)
      held.to_h.transform_keys(&:to_s).merge("state" => held.state.to_s, "disposition" => held.disposition.to_s)
    end

    it "agrees with Timekeeping's reconcile of the same checkpoint, once the client loaded it there" do
      held = rolled_back
      fake = TimekeepingContracts::FakeHandoff.new(generation: rollback_generation, owner: "monolith").install!
      fake.hold!(**held.to_h.except(:generation).merge(reservations: held.reservations.map { |reservation| wire(reservation) }))
      taken = checkpoint
      client.run_step(:close, generation: rollback_generation)
      client.run_step(:freeze, generation:)

      loaded = client.load_recutover_checkpoint(taken)

      expect(client.reconcile_recutover_checkpoint(taken)).to eq(loaded)
      expect(reconcile(taken).to_h).to eq(loaded.to_h)
    end
  end
end
