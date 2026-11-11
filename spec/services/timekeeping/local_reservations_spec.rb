# frozen_string_literal: true

require "rails_helper"

# The prepared application's reservation provider
# (docs/architecture/timekeeping-soa.md §10.2 step 4, §10.5): prepare, commit
# and abort of §5.3 against the local reservation table, decided by the shared
# decision table. The table itself is tested row by row in its package
# (§12.3); these examples prove the provider persists what the table decides
# and keeps the protocol around it.
RSpec.describe Timekeeping::LocalReservations do
  include_context "with two Timekeeping tenants"

  subject(:provider) { described_class.new(entries: entry_store) }

  # An entry store over today's timesheet_entries, standing in for the
  # authoritative store of the owner the provider serves.
  let(:entry_store) do
    Class.new do
      def locked = (@locked ||= [])

      def lock(ids)
        locked << ids
        TimesheetEntry.joins(project: :client).where(id: ids).order(:id).lock("FOR UPDATE OF timesheet_entries")
          .pluck(:id, "clients.company_id")
          .to_h { |id, company_id| [id, TimekeepingReservations::Entry.new(id:, company_id:)] }
      end
    end.new
  end

  let(:x) { unbilled_entry(tenant_a) }
  let(:y) { unbilled_entry(tenant_a) }
  let(:draft) { invoice_for(tenant_a) }
  let(:other_draft) { invoice_for(tenant_a) }
  let(:sent) { invoice_for(tenant_a, status: :sent) }

  def operation(invoice, kind: :save, entry_ids: [], invoice_state: invoice.draft? ? :draft : :non_draft, operation_id: SecureRandom.uuid)
    TimekeepingReservations::Operation.new(invoice_id: invoice.id, operation_id:, company_id: invoice.company_id, kind:, invoice_state:, entry_ids:)
  end

  def reservations
    Timekeeping::Reservation.order(:entry_id, :invoice_id, :state).map { |row| row.to_value.to_h.except(:company_id) }
  end

  def reservation(entry, invoice, state: :committed, disposition: :active, edit_lock: true, operation_id: nil)
    { entry_id: entry.id, invoice_id: invoice.id, operation_id:, state:, disposition:, edit_lock: }
  end

  def receipt(invoice, op)
    Timekeeping::ReservationOperation.find_by(invoice_id: invoice.id, operation_id: op.operation_id)&.state
  end

  def committed!(op)
    expect(provider.prepare(op)).to be_a(described_class::Prepared)
    expect(provider.commit(invoice_id: op.invoice_id, operation_id: op.operation_id)).to eq(described_class::Receipt.new(status: :committed))
  end

  def table_state
    [reservations, Timekeeping::ReservationOperation.order(:id).map { |row| row.attributes.except("created_at", "updated_at") }]
  end

  describe "#prepare" do
    it "reserves a draft's added entries provisionally with the edit lock, and answers their facts" do
      op = operation(draft, entry_ids: [x.id, y.id])

      result = provider.prepare(op)

      aggregate_failures do
        expect(result).to eq(described_class::Prepared.new(entries: [x, y].map { |entry| TimekeepingReservations::Entry.new(id: entry.id, company_id: tenant_a.company.id) }))
        expect(reservations).to eq([x, y].map { |entry| reservation(entry, draft, state: :provisional, operation_id: op.operation_id) })
        expect(receipt(draft, op)).to eq("prepared")
        expect(entry_store.locked).to eq([[x.id, y.id].sort])
      end
    end

    it "reserves a non-draft's added entries without the edit lock" do
      op = operation(sent, entry_ids: [x.id])

      provider.prepare(op)

      expect(reservations).to eq([reservation(x, sent, state: :provisional, edit_lock: false, operation_id: op.operation_id)])
    end

    it "writes no timesheet_entries row: the projection is not the provider's" do
      committed!(operation(draft, entry_ids: [x.id]))

      expect(locked?(x)).to be(false)
    end

    {
      "active on another kept invoice" => :committed!,
      "provisional for another invoice" => :prepare_only
    }.each do |label, how|
      it "refuses an entry #{label} (F1) and changes nothing" do
        held = operation(other_draft, entry_ids: [x.id])
        how == :committed! ? committed!(held) : provider.prepare(held)
        before = table_state
        op = operation(draft, entry_ids: [x.id, y.id])

        result = provider.prepare(op)

        aggregate_failures do
          expect(result).to eq(TimekeepingReservations::Refused.new(refusals: [TimekeepingReservations::Refusal.new(entry_id: x.id, reason: :on_other_invoice)]))
          expect(table_state).to eq(before)
          expect(receipt(draft, op)).to be_nil
        end
      end
    end

    it "refuses an entry that does not exist and one of another company (L8)" do
      op = operation(draft, entry_ids: [bystander_entry.id, 0])

      expect(provider.prepare(op)).to eq(TimekeepingReservations::Refused.new(refusals: [
        TimekeepingReservations::Refusal.new(entry_id: bystander_entry.id, reason: :wrong_company),
        TimekeepingReservations::Refusal.new(entry_id: 0, reason: :not_found)
      ]))
      expect(reservations).to be_empty
    end

    it "is idempotent: a replay answers prepared again and reserves nothing twice" do
      op = operation(draft, entry_ids: [x.id])
      provider.prepare(op)
      before = table_state

      expect(provider.prepare(op)).to be_a(described_class::Prepared)
      expect(table_state).to eq(before)
    end

    it "refuses a replay of an unresolved operation with another body" do
      op = operation(draft, entry_ids: [x.id])
      provider.prepare(op)

      expect { provider.prepare(op.with(entry_ids: [x.id, y.id])) }.to raise_error(described_class::ProtocolError)
    end

    it "answers the stored receipt once the operation is terminal, and changes nothing" do
      op = operation(draft, entry_ids: [x.id])
      committed!(op)
      before = table_state

      expect(provider.prepare(op)).to eq(described_class::Receipt.new(status: :committed))
      expect(table_state).to eq(before)
    end

    context "when the invoice has an earlier unresolved operation (§5.3)" do
      let(:earlier) { operation(draft, entry_ids: [x.id]) }
      let(:later) { operation(draft, entry_ids: [y.id]) }

      before { provider.prepare(earlier) }

      it "refuses as unresolved, naming it, and changes nothing" do
        before = table_state

        expect(provider.prepare(later)).to eq(described_class::Unresolved.new(operation_id: earlier.operation_id))
        expect(table_state).to eq(before)
      end

      it "refuses when resolves names another operation" do
        expect(provider.prepare(later, resolves: { operation_id: SecureRandom.uuid, outcome: :aborted }))
          .to eq(described_class::Unresolved.new(operation_id: earlier.operation_id))
      end

      it "resolves it with the outcome resolves carries, then prepares" do
        result = provider.prepare(later, resolves: { operation_id: earlier.operation_id, outcome: :aborted })

        aggregate_failures do
          expect(result).to be_a(described_class::Prepared)
          expect(receipt(draft, earlier)).to eq("aborted")
          expect(reservations).to eq([reservation(y, draft, state: :provisional, operation_id: later.operation_id)])
        end
      end
    end
  end

  describe "#commit" do
    it "makes a draft's prepared entries active with the edit lock, and replays its receipt" do
      op = operation(draft, entry_ids: [x.id])
      committed!(op)
      before = table_state

      aggregate_failures do
        expect(reservations).to eq([reservation(x, draft)])
        expect(provider.commit(invoice_id: draft.id, operation_id: op.operation_id)).to eq(described_class::Receipt.new(status: :committed))
        expect(table_state).to eq(before)
      end
    end

    it "answers not prepared for an operation never prepared, and records nothing" do
      operation_id = SecureRandom.uuid

      expect(provider.commit(invoice_id: draft.id, operation_id:)).to eq(described_class::NotPrepared.new(operation_id:))
      expect(table_state).to eq([[], []])
    end

    it "releases a draft's removed entry and keeps the one a remaining line still references (F3)" do
      committed!(operation(draft, entry_ids: [x.id, y.id]))

      committed!(operation(draft, entry_ids: [x.id]))

      expect(reservations).to eq([reservation(x, draft)])
    end

    it "keeps a non-draft's removed entry as retained (L4)" do
      committed!(operation(sent, entry_ids: [x.id, y.id]))

      committed!(operation(sent, entry_ids: [x.id]))

      expect(reservations).to eq([reservation(x, sent, edit_lock: false), reservation(y, sent, disposition: :retained, edit_lock: false)])
    end

    it "releases every entry of a discarded draft (F2)" do
      committed!(operation(draft, entry_ids: [x.id, y.id]))

      committed!(operation(draft, kind: :discard))

      expect(reservations).to be_empty
    end

    %i[discard destroy].each do |kind|
      it "keeps every entry of a #{kind}ed non-draft retained, and a successor succeeds it" do
        committed!(operation(sent, entry_ids: [x.id]))
        committed!(operation(sent, kind:))
        expect(reservations).to eq([reservation(x, sent, disposition: :retained, edit_lock: false)])

        successor = operation(draft, entry_ids: [x.id])
        provider.prepare(successor)
        expect(reservations).to contain_exactly(
          reservation(x, draft, state: :provisional, operation_id: successor.operation_id),
          reservation(x, sent, disposition: :retained, edit_lock: false)
        )

        provider.commit(invoice_id: draft.id, operation_id: successor.operation_id)
        expect(reservations).to eq([reservation(x, draft)])
      end
    end
  end

  describe "#abort" do
    it "drops only the operation's provisional reservations and keeps the committed ones" do
      committed!(operation(draft, entry_ids: [x.id]))
      op = operation(draft, entry_ids: [x.id, y.id])
      provider.prepare(op)

      expect(provider.abort(invoice_id: draft.id, operation_id: op.operation_id)).to eq(described_class::Receipt.new(status: :aborted))
      expect(reservations).to eq([reservation(x, draft)])
    end

    it "keeps a retained reservation when its successor aborts" do
      committed!(operation(sent, entry_ids: [x.id]))
      committed!(operation(sent, kind: :discard))
      successor = operation(draft, entry_ids: [x.id])
      provider.prepare(successor)

      provider.abort(invoice_id: draft.id, operation_id: successor.operation_id)

      expect(reservations).to eq([reservation(x, sent, disposition: :retained, edit_lock: false)])
    end

    it "records an aborted receipt for an operation never prepared, and changes nothing else (§9.3)" do
      op = operation(draft)

      expect(provider.abort(invoice_id: draft.id, operation_id: op.operation_id)).to eq(described_class::Receipt.new(status: :aborted))
      aggregate_failures do
        expect(receipt(draft, op)).to eq("aborted")
        expect(reservations).to be_empty
        expect(provider.prepare(op)).to eq(described_class::Receipt.new(status: :aborted))
      end
    end

    it "does not undo a committed operation" do
      op = operation(draft, entry_ids: [x.id])
      committed!(op)

      expect(provider.abort(invoice_id: draft.id, operation_id: op.operation_id)).to eq(described_class::Receipt.new(status: :committed))
      expect(reservations).to eq([reservation(x, draft)])
    end
  end

  it "locks the operation's desired set and every entry the invoice holds, in id order" do
    committed!(operation(draft, entry_ids: [y.id]))
    entry_store.locked.clear

    provider.prepare(operation(draft, entry_ids: [x.id]))

    expect(entry_store.locked).to eq([[x.id, y.id].sort])
  end

  it "rolls back every change of a call that fails part way, and nothing of its caller's" do
    earlier = operation(draft, entry_ids: [x.id])
    provider.prepare(earlier)
    before = table_state
    # Resolving the earlier operation locks and writes; locking for the
    # new operation then fails.
    calls = 0
    entry_store.define_singleton_method(:lock) { |ids| (calls += 1) > 1 ? raise(ActiveRecord::LockWaitTimeout) : super(ids) }
    caller_row = nil

    ActiveRecord::Base.transaction do
      caller_row = Timekeeping::ReservationOperation.create!(invoice_id: other_draft.id, operation_id: SecureRandom.uuid, state: :aborted)
      expect { provider.prepare(operation(draft, entry_ids: [y.id]), resolves: { operation_id: earlier.operation_id, outcome: :aborted }) }
        .to raise_error(ActiveRecord::LockWaitTimeout)
    end

    expect(calls).to eq(2)
    expect(table_state).to eq([before.first, before.last + [caller_row.reload.attributes.except("created_at", "updated_at")]])
  end
end
