# frozen_string_literal: true

require "rails_helper"

# Step 6 of the first cutover on the existing application's side
# (docs/architecture/timekeeping-soa.md §10.5, §10.4 "Reconciliation"): the
# legacy checkpoint against this application's own tables. Reservations
# against kept invoices' lines and links, the projection once the relay has
# delivered the load's snapshots, and money, each exact, on two tenants. Each
# billing state is reached through the behaviour that produces it today, and
# the handoff is frozen only once it is built, as the fence refuses every
# billing write after it. A difference is made afterwards with relation-level
# writes, which no fence or callback sees.
RSpec.describe Timekeeping::CheckpointReconcile, type: :model do
  include_context "with two Timekeeping tenants"

  let(:relay) { TimekeepingContracts::FakeRelay.new }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 90.7) }
  let!(:grouped_entries) { [unbilled_entry(tenant_a, duration: 0.1), unbilled_entry(tenant_a, duration: 479.99999)] }
  let!(:retained_entry) { unbilled_entry(tenant_a) }
  let!(:released_entry) { unbilled_entry(tenant_a) }
  let!(:linked_entry) { unbilled_entry(tenant_b) }
  let!(:discarded_entry) { unbilled_entry(tenant_a).tap(&:discard!) }

  # A direct and a grouped draft (L1), a sent invoice discarded after a draft
  # save (L3, retained), a discarded draft (F2, released), and tenant B's
  # invoice created sent, whose entry no draft save ever locked (an unlocked
  # link with its recorded disposition).
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
  let!(:discarded_draft) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, released_entry)
      invoice.reload.save!
      invoice.discard!
    end
  end
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  # Taken before the handoff closes admission, as the handoff tool takes it.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  let(:checkpoint) do
    freeze_handoff!
    Timekeeping::LegacyCheckpoint.take(generation: 1, unlocked_link_invoice_ids: [unlocked_link_invoice.id])
  end

  def freeze_handoff!(generation: 1, owner: "legacy", state: "frozen")
    set_timekeeping_ownership!(generation:, owner:, state:)
  end

  # The relay delivering every snapshot the checkpoint's load wrote: one per
  # entry, at its checkpoint version.
  def deliver!(entries = checkpoint.entries)
    snapshots = entries.map do |entry|
      relay.snapshot(
        entry_id: entry.fetch("id"), version: entry.fetch("version"), company_id: entry.fetch("company_id"),
        **entry.except("id", "version", "company_id").symbolize_keys
      )
    end
    expect(Timekeeping::ProjectionConsumer.process(snapshots)).to be_a(Timekeeping::ProjectionConsumer::Applied)
  end

  def reconcile(entries: checkpoint.entries, reservations: checkpoint.reservations, financial_snapshot: money_before)
    described_class.call(generation: 1, entries:, reservations:, financial_snapshot:)
  end

  # The lists a reconcile that must fail names.
  def differs(**carried)
    lists = nil
    expect { reconcile(**carried) }.to raise_error(described_class::Differs) { |error| lists = error.lists }
    lists
  end

  def entry_of(target)
    checkpoint.entries.find { |entry| entry.fetch("id") == target.id }
  end

  def without(reservations, target)
    reservations.reject { |reservation| reservation.entry_id == target.id }
  end

  def replaced(reservations, target, **changes)
    reservations.map { |reservation| reservation.entry_id == target.id ? reservation.with(**changes) : reservation }
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { generation: 1, owner: "legacy", state: "open" },
      "admission closed, not frozen" => { generation: 1, owner: "legacy", state: "closed" },
      "frozen at another generation" => { generation: 2, owner: "legacy", state: "frozen" },
      "frozen while Timekeeping is the outgoing owner" => { generation: 1, owner: "timekeeping", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}" do
        carried = checkpoint
        deliver!
        set_timekeeping_ownership!(ownership)

        expect { reconcile(entries: carried.entries, reservations: carried.reservations) }
          .to raise_error(described_class::OutOfStep, /reconcile expects .*nothing changed/)
      end
    end

    it "refuses on a database where no handoff has run" do
      expect { reconcile(entries: [], reservations: []) }.to raise_error(described_class::OutOfStep)
    end
  end

  describe "a checkpoint that agrees" do
    it "reconciles every entry, reservation and value of both tenants" do
      deliver!

      expect(reconcile).to eq(described_class::Reconciled.new(entries: TimesheetEntry.count, reservations: 5))
      expect(checkpoint.reservations.map(&:disposition).tally).to eq(active: 4, retained: 1)
    end

    it "reconciles the checkpoint and the financial snapshot as the handoff tool carries them, through JSON" do
      deliver!
      entries = JSON.parse(JSON.generate(checkpoint.entries))
      money = JSON.parse(JSON.generate(money_before))

      expect(entries.map { |entry| entry.fetch("duration") }).to include(90.7, 0.1, 479.99999)
      expect(reconcile(entries:, financial_snapshot: money)).to be_a(described_class::Reconciled)
    end

    it "writes nothing, and leaves the handoff frozen" do
      deliver!
      tables = %w[timesheet_entries invoices invoice_line_items invoice_line_item_time_entries invoice_taxes timekeeping_ownerships]
      rows = -> { tables.index_with { |table| ActiveRecord::Base.connection.select_rows("SELECT * FROM #{table} ORDER BY id") } }

      expect { reconcile }.not_to change(&rows)
      expect(Timekeeping::Ownership.current).to have_attributes(generation: 1, owner: "legacy", state: "frozen")
    end
  end

  describe "reservations against kept invoices" do
    before { deliver! }

    it "lists an entry a kept invoice references directly with no active reservation" do
      expect(differs(reservations: without(checkpoint.reservations, draft_entry)))
        .to eq(reference_without_reservation: [draft_entry.id])
    end

    it "lists a grouped line's linked entry with no active reservation" do
      expect(differs(reservations: without(checkpoint.reservations, grouped_entries.last)))
        .to eq(reference_without_reservation: [grouped_entries.last.id])
    end

    it "lists an unlocked link with no active reservation, on the other tenant" do
      expect(differs(reservations: without(checkpoint.reservations, linked_entry)))
        .to eq(reference_without_reservation: [linked_entry.id])
    end

    it "lists an active reservation held by another invoice than the one that references the entry" do
      reservations = replaced(checkpoint.reservations, draft_entry, invoice_id: unlocked_link_invoice.id)

      expect(differs(reservations:)).to eq(reference_without_reservation: [draft_entry.id], reservation_without_reference: [draft_entry.id])
    end

    it "lists an active reservation of another tenant than the invoice's" do
      reservations = replaced(checkpoint.reservations, draft_entry, company_id: tenant_b.company.id)

      expect(differs(reservations:)).to eq(reference_without_reservation: [draft_entry.id], reservation_without_reference: [draft_entry.id])
    end

    it "lists an active reservation by a discarded invoice" do
      reservations = replaced(checkpoint.reservations, retained_entry, disposition: :active)

      expect(differs(reservations:)).to eq(reservation_without_reference: [retained_entry.id])
    end

    it "lists an active reservation of an entry no kept invoice references" do
      extra = TimekeepingReservations::Reservation.new(
        entry_id: released_entry.id, invoice_id: draft.id, company_id: tenant_a.company.id,
        operation_id: nil, state: :committed, disposition: :active, edit_lock: true
      )

      expect(differs(reservations: checkpoint.reservations + [extra])).to eq(reservation_without_reference: [released_entry.id])
    end

    it "does not count a retained reservation as a reference (L3)" do
      expect(reconcile(reservations: without(checkpoint.reservations, retained_entry))).to be_a(described_class::Reconciled)
    end
  end

  describe "the projection" do
    it "lists every entry while the relay has not yet delivered the load's snapshots" do
      expect(differs).to eq(projection_differs: TimesheetEntry.order(:id).ids)
    end

    it "lists an entry whose last snapshot the projection has not taken" do
      deliver!
      TimesheetEntry.where(id: released_entry.id).update_all(locked: true)

      expect(differs).to eq(projection_differs: [released_entry.id])
    end

    it "lists a duration off by the last bit" do
      deliver!
      TimesheetEntry.where(id: draft_entry.id).update_all(duration: 90.7.next_float)

      expect(differs).to eq(projection_differs: [draft_entry.id])
    end

    it "lists a timestamp off by one microsecond" do
      deliver!
      TimesheetEntry.where(id: discarded_entry.id).update_all(["discarded_at = discarded_at + interval '1 microsecond'"])

      expect(differs).to eq(projection_differs: [discarded_entry.id])
    end

    it "lists an entry the checkpoint carries that the projection does not hold" do
      deliver!
      TimesheetEntry.where(id: released_entry.id).delete_all

      expect(differs).to eq(projection_missing: [released_entry.id])
    end

    it "lists an entry the projection holds that the checkpoint does not carry" do
      deliver!

      expect(differs(entries: checkpoint.entries - [entry_of(bystander_entry)])).to eq(projection_unexpected: [bystander_entry.id])
    end

    it "lists an entry carried under another tenant" do
      deliver!
      entries = checkpoint.entries.map { |entry| entry.fetch("id") == linked_entry.id ? entry.merge("company_id" => tenant_a.company.id) : entry }

      expect(differs(entries:)).to eq(projection_differs: [linked_entry.id])
    end
  end

  describe "money" do
    before { deliver! }

    it "lists an invoice value that changed" do
      Invoice.where(id: draft.id).update_all(amount: draft.amount + 0.01)

      expect(differs).to eq(money_differs: ["invoices/#{draft.id}/amount"])
    end

    it "lists a line item that is gone" do
      line = draft.invoice_line_items.find_by!(timesheet_entry: draft_entry)
      InvoiceLineItem.where(id: line.id).delete_all

      expect(differs).to include(money_differs: include("invoice_line_items/#{line.id}"))
    end
  end

  it "lists every difference at once, across both tenants, and names them in its message" do
    deliver!
    TimesheetEntry.where(id: bystander_entry.id).update_all(duration: 1.5)
    Invoice.where(id: unlocked_link_invoice.id).update_all(discount: 1)

    expect { reconcile(reservations: without(checkpoint.reservations, draft_entry)) }
      .to raise_error(described_class::Differs) { |error|
        expect(error.lists).to eq(
          reference_without_reservation: [draft_entry.id],
          projection_differs: [bystander_entry.id],
          money_differs: ["invoice_pdf_totals/#{unlocked_link_invoice.id}/total", "invoices/#{unlocked_link_invoice.id}/discount"]
        )
        expect(error.message).to start_with("Timekeeping checkpoint reconcile: reference_without_reservation #{draft_entry.id}; ")
        expect(error.message).to end_with("; abort the handoff")
      }
  end
end
