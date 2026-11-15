# frozen_string_literal: true

require "rails_helper"

# The prepared application's entry store (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): what Timekeeping::LocalReservations locks and reads its facts
# from once the `monolith` owner is built. Nothing routes to it yet.
RSpec.describe Timekeeping::LocalEntries do
  subject(:store) { described_class.new }

  def entry!(id:, company_id:, discarded_at: nil)
    Timekeeping::Entry.create!(
      id:, company_id:, project_id: 7, user_id: 9, duration: 60.0, work_date: Date.new(2026, 11, 2),
      bill_status: "unbilled", discarded_at:
    )
  end

  def statements(&)
    sql = []
    record = ->(*, payload) { sql << payload[:sql] if payload[:sql].include?("timekeeping_entries") }
    ActiveSupport::Notifications.subscribed(record, "sql.active_record", &)
    sql
  end

  describe "#lock" do
    it "answers each entry that exists by id with its company, discarded ones included" do
      entry!(id: 3, company_id: 42)
      entry!(id: 1, company_id: 43, discarded_at: Time.current)

      expect(store.lock([3, 2, 1])).to eq(
        1 => TimekeepingReservations::Entry.new(id: 1, company_id: 43),
        3 => TimekeepingReservations::Entry.new(id: 3, company_id: 42)
      )
    end

    it "takes the rows FOR UPDATE in id order (§9.4)" do
      entry!(id: 1, company_id: 42)

      sql = statements { store.lock([1]) }

      expect(sql).to contain_exactly(a_string_matching(/ORDER BY "timekeeping_entries"\."id" ASC FOR UPDATE\z/))
    end

    it "answers nothing for no ids" do
      expect(store.lock([])).to eq({})
    end
  end

  describe "#reservations_changed!" do
    let(:company) { create(:company) }
    let(:operation) do
      TimekeepingReservations::Operation.new(
        invoice_id: 10, operation_id: SecureRandom.uuid, company_id: company.id, kind: :save, invoice_state: :draft, entry_ids: []
      )
    end

    around do |example|
      example.run
    ensure
      Rails.event.clear_context
    end

    def reserve!(entry, edit_lock: true)
      Timekeeping::Reservation.create!(
        entry_id: entry.id, invoice_id: 10, company_id: entry.company_id, state: "committed", disposition: "active", edit_lock:
      )
    end

    it "saves each named entry as its next version, with a snapshot carrying `locked` and no audit row" do
      first, second = entry!(id: 1, company_id: company.id), entry!(id: 2, company_id: company.id)
      reserve!(first)
      Rails.event.set_context(request_id: "req-local")

      store.reservations_changed!({ 1 => false, 2 => true }, operation:)

      aggregate_failures do
        [[first, true], [second, false]].each do |entry, locked|
          entry.reload
          snapshot = entry.outbox_snapshots.sole
          expect(entry.version).to eq(2)
          expect(snapshot.snapshot).to eq(Timekeeping::OutboxSnapshot.of(entry))
          expect(snapshot.snapshot).to include("version" => 2)
          expect(snapshot.snapshot.dig("data", "locked")).to be(locked)
          expect { TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", snapshot.snapshot) }.not_to raise_error
          expect(snapshot.request_id).to eq("req-local")
        end
        expect(Timekeeping::EntryAudit.count).to eq(0)
      end
    end

    it "moves updated_at only for an entry whose `locked` changed, as today's update!(locked:) touches it" do
      flipped, kept = entry!(id: 1, company_id: company.id), entry!(id: 2, company_id: company.id)
      [flipped, kept].each { |entry| reserve!(entry) }
      stamps = [flipped, kept].map { |entry| entry.reload.updated_at }

      travel(1.minute) { store.reservations_changed!({ 1 => false, 2 => true }, operation:) }

      expect([flipped, kept].map { |entry| entry.reload.updated_at }).to match([be > stamps.first, eq(stamps.last)])
    end

    it "leaves an entry it is not told about alone" do
      entry!(id: 1, company_id: company.id)
      bystander = entry!(id: 2, company_id: company.id)

      store.reservations_changed!({ 1 => false }, operation:)

      expect([bystander.reload.version, bystander.outbox_snapshots.count]).to eq([1, 0])
    end
  end

  describe "as the local reservation provider's entry store" do
    include_context "with two Timekeeping tenants"
    include TimekeepingSingleWriterGuard

    subject(:provider) { Timekeeping::LocalReservations.new(entries: store) }

    let(:company) { tenant_a.company }

    def operation(entry_ids, company_id: company.id, invoice_state: :draft, kind: :save, invoice_id: 10)
      TimekeepingReservations::Operation.new(
        invoice_id:, operation_id: SecureRandom.uuid, company_id:, kind:, invoice_state:, entry_ids:
      )
    end

    def committed!(op)
      provider.prepare(op)
      provider.commit(invoice_id: op.invoice_id, operation_id: op.operation_id)
    end

    # An entry the prepared application holds, on a real project and user,
    # so the projection can take its snapshots.
    def held_entry(tenant = tenant_a, id: TimesheetEntry.maximum(:id).to_i + 1_000)
      Timekeeping::Entry.create!(
        id:, company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
        duration: 60.0, work_date: Date.current, bill_status: "unbilled"
      )
    end

    def snapshots(entry)
      entry.outbox_snapshots.order(:version).map { |row| row.snapshot.values_at("version").push(row.snapshot.dig("data", "locked")) }
    end

    it "reserves the prepared application's entries, and its rows decide `locked`" do
      entry = entry!(id: 1, company_id: company.id)
      op = operation([1])

      aggregate_failures do
        expect(provider.prepare(op)).to eq(
          Timekeeping::LocalReservations::Prepared.new(entries: [TimekeepingReservations::Entry.new(id: 1, company_id: company.id)])
        )
        expect(provider.commit(invoice_id: 10, operation_id: op.operation_id))
          .to eq(Timekeeping::LocalReservations::Receipt.new(status: :committed))
        expect(entry.reload.to_contract).to include("locked" => true)
      end
    end

    it "refuses an entry it does not hold and another company's, with nothing reserved or written (L8)" do
      other = entry!(id: 2, company_id: tenant_b.company.id)

      aggregate_failures do
        expect(provider.prepare(operation([1, 2]))).to eq(TimekeepingReservations::Refused.new(refusals: [
          TimekeepingReservations::Refusal.new(entry_id: 1, reason: :not_found),
          TimekeepingReservations::Refusal.new(entry_id: 2, reason: :wrong_company)
        ]))
        expect(Timekeeping::Reservation.count).to eq(0)
        expect([other.reload.version, Timekeeping::OutboxSnapshot.count]).to eq([1, 0])
      end
    end

    it "gives a draft's entry a version and snapshot at each change, as Timekeeping's prepare and commit do (§5.4)" do
      entry = held_entry
      created_at = entry.reload.updated_at
      op = operation([entry.id])

      travel(1.minute) { provider.prepare(op) }
      prepared_at = entry.reload.updated_at
      travel(2.minutes) { provider.commit(invoice_id: 10, operation_id: op.operation_id) }

      aggregate_failures do
        expect(snapshots(entry)).to eq([[2, true], [3, true]])
        expect(prepared_at).to be > created_at
        expect(entry.reload).to have_attributes(version: 3, updated_at: prepared_at)
        expect(Timekeeping::EntryAudit.count).to eq(0)
      end
    end

    it "keeps a non-draft's entry unlocked and its updated_at, while still versioning it (L1)" do
      entry = held_entry
      updated_at = entry.reload.updated_at

      travel(1.minute) { committed!(operation([entry.id], invoice_state: :non_draft)) }

      expect(snapshots(entry)).to eq([[2, false], [3, false]])
      expect(entry.reload).to have_attributes(version: 3, updated_at:)
    end

    it "snapshots the release of a removed entry (F3) and of an aborted prepare as unlocked" do
      kept, removed = held_entry, held_entry(id: TimesheetEntry.maximum(:id).to_i + 1_001)
      committed!(operation([kept.id, removed.id]))
      committed!(operation([kept.id]))
      aborted = held_entry(id: TimesheetEntry.maximum(:id).to_i + 1_002)
      op = operation([kept.id, aborted.id])
      provider.prepare(op)
      provider.abort(invoice_id: 10, operation_id: op.operation_id)

      aggregate_failures do
        expect(snapshots(kept)).to eq([[2, true], [3, true]])
        expect(snapshots(removed)).to eq([[2, true], [3, true], [4, false]])
        expect(snapshots(aborted)).to eq([[2, true], [3, false]])
      end
    end

    it "writes no timesheet_entries row; the local relay projects the derived `locked` (§3.3)" do
      entry = held_entry
      Timekeeping::LocalEntryChange.record!(entry, action: "create", audited_changes: {}, claims: { "request_id" => "req-create" })
      Timekeeping::LocalRelay.new.run
      op = operation([entry.id])

      writes = timesheet_entry_writes { committed!(op) }

      expect(writes).to eq([])
      expect(TimesheetEntry.find(entry.id)).to have_attributes(locked: false, version: 1)
      Timekeeping::LocalRelay.new.run
      expect(TimesheetEntry.find(entry.id)).to have_attributes(locked: true, version: 3)

      committed!(operation([], kind: :discard))
      Timekeeping::LocalRelay.new.run
      expect(TimesheetEntry.find(entry.id)).to have_attributes(locked: false, version: 4)
    end
  end
end
