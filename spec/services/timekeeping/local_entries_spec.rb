# frozen_string_literal: true

require "rails_helper"

# The prepared application's entry store (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): what Timekeeping::LocalReservations locks and reads its facts
# from once the `monolith` owner is built, and the candidates invoice
# selection reads under that owner.
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

  describe "#prepared" do
    def facts(id:, company_id:, version: 1)
      Timekeeping::ReservationClient::PreparedEntry.new(
        id:, company_id:, project_id: 7, user_id: 9, duration: 60.0, work_date: "2026-11-02", version:
      )
    end

    it "answers each entry that exists with its prepare facts, in the order asked, discarded ones included" do
      entry!(id: 3, company_id: 42)
      entry!(id: 1, company_id: 43, discarded_at: Time.current).update!(version: 4)

      expect(store.prepared([3, 2, 1])).to eq([facts(id: 3, company_id: 42), facts(id: 1, company_id: 43, version: 4)])
    end

    it "answers the contract's prepared entry, as the reservation client takes it" do
      entry = entry!(id: 1, company_id: 42)
      entry.update!(duration: 479.99999)

      answered = store.prepared([1]).sole.to_h.stringify_keys

      aggregate_failures do
        expect(Timekeeping::Contracts.errors(:reservation_api, "#/$defs/prepared_entry", answered)).to eq([])
        expect(Timekeeping::ReservationClient::PreparedEntry.members.map(&:to_s)).to eq(Timekeeping::Entry::PREPARED_FIELDS)
        expect(answered).to include("duration" => 479.99999, "work_date" => "2026-11-02")
      end
    end

    it "answers nothing for no ids" do
      expect(store.prepared([])).to eq([])
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

  describe "#candidates" do
    let(:company) { Company.new(id: 42) }
    let(:project_id) { 7 }

    def held!(id, company_id: 42, project_id: 7, user_id: 9, **attributes)
      Timekeeping::Entry.create!(
        id:, company_id:, project_id:, user_id:, duration: 60.0, work_date: Date.new(2026, 11, 2),
        bill_status: "unbilled", **attributes
      )
    end

    def reserve!(entry, state:, disposition:, invoice_id: 10)
      Timekeeping::Reservation.create!(
        entry_id: entry.id, invoice_id:, company_id: entry.company_id, state:, disposition:, edit_lock: true,
        operation_id: (SecureRandom.uuid if state == "provisional")
      )
    end

    def candidate_ids(**query)
      store.candidates(company:, client_id: 3, project_ids: [project_id], **query).map(&:id)
    end

    it "answers each kept, unbilled entry of the company's named projects as the entry client's Candidate, by id" do
      second = held!(5, note: "Second", duration: 90.7, work_date: Date.new(2026, 11, 3))
      first = held!(4)
      held!(6, discarded_at: Time.current)
      held!(7, bill_status: "billed")
      held!(8, bill_status: "non_billable")
      held!(9, project_id: 70)
      held!(10, company_id: 43)

      answered = store.candidates(company:, client_id: 3, project_ids: [project_id])

      expect(answered.map(&:id)).to eq([first.id, second.id])
      expect(answered.last).to eq(Timekeeping::EntryClient::Candidate.new(
        id: 5, company_id: 42, project_id: 7, user_id: 9, note: "Second", work_date: Date.new(2026, 11, 3), duration: 90.7
      ))
    end

    it "leaves out an entry an invoice holds by an active or a provisional reservation, not by a retained one (L3, L4)" do
      active, provisional, retained, free = [1, 2, 3, 4].map { |id| held!(id) }
      reserve!(active, state: "committed", disposition: "active")
      reserve!(provisional, state: "provisional", disposition: "active")
      reserve!(retained, state: "committed", disposition: "retained")

      expect(candidate_ids).to eq([retained.id, free.id])
    end

    it "narrows by each filter the entry client carries" do
      mine = held!(1, user_id: 9, work_date: Date.new(2026, 11, 2))
      held!(2, user_id: 11, work_date: Date.new(2026, 11, 2))
      selected = held!(3, user_id: 9, work_date: Date.new(2026, 11, 3))
      held!(4, user_id: 9, work_date: Date.new(2026, 10, 1))

      expect(candidate_ids(user_ids: [9], exclude_ids: [selected.id], work_dates: Date.new(2026, 11, 1)..Date.new(2026, 11, 30)))
        .to eq([mine.id])
      expect(candidate_ids(user_ids: nil).size).to eq(4)
      expect(candidate_ids(user_ids: [])).to eq([])
      expect(store.candidates(company:, client_id: 3, project_ids: [])).to eq([])
    end

    # The search GenerateInvoice::NewLineItemsService runs today through
    # TimesheetEntry.pg_search, as Timekeeping's own candidates spec pins it.
    describe "search_term" do
      let!(:prep) { held!(1, note: "Salad prep for the lunch menu") }
      let!(:baking) { held!(2, note: "Baking sourdough") }
      let!(:lunch) { held!(3, note: "Lunch salads, lunch service, lunch prep") }
      let!(:silent) { held!(4, note: nil) }

      {
        "a word prefix" => ["sal", -> { [prep, lunch] }],
        "an english stem" => ["bakes", -> { [baking] }],
        "every word of the term" => ["lunch prep", -> { [lunch, prep] }],
        "a term in any case" => ["SOURDOUGH", -> { [baking] }],
        "a word nothing matches" => ["invoice", -> { [] }]
      }.each do |name, (term, expected)|
        it "matches #{name}" do
          expect(candidate_ids(search_term: term)).to eq(instance_exec(&expected).map(&:id))
        end
      end

      it "orders by rank first, then by id" do
        expect(candidate_ids(search_term: "lunch")).to eq([lunch.id, prep.id])
      end

      it "treats quotes, colons and question marks as spaces instead of failing the query" do
        expect(candidate_ids(search_term: "salad's: prep?")).to contain_exactly(prep.id, lunch.id)
      end

      it "is no search when blank" do
        expect(candidate_ids(search_term: " ")).to eq([prep, baking, lunch, silent].map(&:id))
      end
    end

    it "reads only the prepared application's table, never the projection" do
      held!(1)
      sql = []
      record = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(record, "sql.active_record") { candidate_ids(search_term: "x") }

      expect(sql.grep(/timesheet_entries/)).to eq([])
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
        expect(provider.prepare(op).entries.map { |facts| facts.to_h.slice(:id, :company_id) }).to eq([{ id: 1, company_id: company.id }])
        expect(provider.commit(invoice_id: 10, operation_id: op.operation_id))
          .to eq(Timekeeping::LocalReservations::Receipt.new(status: :committed))
        expect(entry.reload.to_contract).to include("locked" => true)
      end
    end

    it "answers the desired set's facts at the versions the prepare left them, as Timekeeping's prepare does (L8)" do
      kept = held_entry
      committed!(operation([kept.id], invoice_state: :non_draft))
      added = held_entry(id: kept.id + 1)
      added.update!(duration: 479.99999)

      result = provider.prepare(operation([added.id, kept.id], invoice_state: :non_draft))

      aggregate_failures do
        expect(result.entries).to eq([
          Timekeeping::ReservationClient::PreparedEntry.new(
            id: added.id, company_id: company.id, project_id: tenant_a.project.id, user_id: tenant_a.employee.id,
            duration: 479.99999, work_date: Date.current.iso8601, version: 2
          ),
          Timekeeping::ReservationClient::PreparedEntry.new(
            id: kept.id, company_id: company.id, project_id: tenant_a.project.id, user_id: tenant_a.employee.id,
            duration: 60.0, work_date: Date.current.iso8601, version: 3
          )
        ])
        expect([added.reload.version, kept.reload.version]).to eq([2, 3])
      end
    end

    it "hands line-item validation the same references as Timekeeping's prepared answer" do
      entry = held_entry
      prepared = provider.prepare(operation([entry.id]))

      references = Timekeeping::EntryReferences.within(prepared.entries) { Timekeeping::EntryReferences.current.find([entry.id]) }

      expect(references).to eq(entry.id => Timekeeping::EntryReferences::Reference.new(id: entry.id, company_id: company.id))
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
