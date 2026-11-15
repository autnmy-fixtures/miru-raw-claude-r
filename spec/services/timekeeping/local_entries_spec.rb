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

  describe "as the local reservation provider's entry store" do
    subject(:provider) { Timekeeping::LocalReservations.new(entries: store) }

    def operation(entry_ids, company_id: 42)
      TimekeepingReservations::Operation.new(
        invoice_id: 10, operation_id: SecureRandom.uuid, company_id:, kind: :save, invoice_state: :draft, entry_ids:
      )
    end

    it "reserves the prepared application's entries, and its rows decide `locked`" do
      entry = entry!(id: 1, company_id: 42)
      op = operation([1])

      aggregate_failures do
        expect(provider.prepare(op)).to eq(
          Timekeeping::LocalReservations::Prepared.new(entries: [TimekeepingReservations::Entry.new(id: 1, company_id: 42)])
        )
        expect(provider.commit(invoice_id: 10, operation_id: op.operation_id))
          .to eq(Timekeeping::LocalReservations::Receipt.new(status: :committed))
        expect(entry.reload.to_contract).to include("locked" => true)
      end
    end

    it "refuses an entry it does not hold and another company's, with nothing reserved (L8)" do
      entry!(id: 2, company_id: 43)

      aggregate_failures do
        expect(provider.prepare(operation([1, 2]))).to eq(TimekeepingReservations::Refused.new(refusals: [
          TimekeepingReservations::Refusal.new(entry_id: 1, reason: :not_found),
          TimekeepingReservations::Refusal.new(entry_id: 2, reason: :wrong_company)
        ]))
        expect(Timekeeping::Reservation.count).to eq(0)
      end
    end
  end
end
