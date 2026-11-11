# frozen_string_literal: true

require "rails_helper"

# The prepared application's reservation tables
# (docs/architecture/timekeeping-soa.md §7.1, §5.3, §10.2 step 4). The rule is
# the shared decision table's; these are the database's backstops for it, in
# case a caller ever writes around the provider's locks.
RSpec.describe "Timekeeping local reservation tables", type: :model do
  def reservation!(**attributes)
    Timekeeping::Reservation.create!(
      { entry_id: 1, invoice_id: 10, company_id: 42, operation_id: nil, state: "committed", disposition: "active", edit_lock: true }.merge(attributes)
    )
  end

  def operation!(**attributes)
    Timekeeping::ReservationOperation.create!(
      { invoice_id: 10, operation_id: SecureRandom.uuid, company_id: 42, kind: "save", invoice_state: "draft", entry_ids: [1], state: "prepared" }.merge(attributes)
    )
  end

  def refused(&)
    expect { ActiveRecord::Base.transaction(requires_new: true, &) }
  end

  describe Timekeeping::Reservation do
    it "round-trips a row and its rule value" do
      value = TimekeepingReservations::Reservation.new(
        entry_id: 1, invoice_id: 10, company_id: 42, operation_id: SecureRandom.uuid,
        state: :provisional, disposition: :active, edit_lock: false
      )

      expect(described_class.create!(described_class.row_for(value)).reload.to_value).to eq(value)
    end

    it "holds at most one active or provisional reservation per entry (F1)" do
      reservation!

      aggregate_failures do
        refused { reservation!(invoice_id: 11) }.to raise_error(ActiveRecord::RecordNotUnique)
        refused { reservation!(invoice_id: 11, state: "provisional", operation_id: SecureRandom.uuid) }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    it "lets a retained reservation sit beside the entry's live one: it does not count (§7.1)" do
      reservation!(disposition: "retained")

      expect { reservation!(invoice_id: 11, state: "provisional", operation_id: SecureRandom.uuid) }.not_to raise_error
    end

    it "identifies a committed reservation by (entry, invoice)" do
      reservation!(disposition: "retained")

      refused { reservation!(disposition: "retained") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "gives a provisional reservation its operation, a committed one none, and a provisional one no retained disposition" do
      aggregate_failures do
        refused { reservation!(state: "provisional") }.to raise_error(ActiveRecord::StatementInvalid, /operation_iff_provisional/)
        refused { reservation!(operation_id: SecureRandom.uuid) }.to raise_error(ActiveRecord::StatementInvalid, /operation_iff_provisional/)
        refused { reservation!(state: "provisional", operation_id: SecureRandom.uuid, disposition: "retained") }
          .to raise_error(ActiveRecord::StatementInvalid, /provisional_active/)
      end
    end
  end

  describe Timekeeping::ReservationOperation do
    it "round-trips a row and its rule operation" do
      operation = TimekeepingReservations::Operation.new(
        invoice_id: 10, operation_id: SecureRandom.uuid, company_id: 42, kind: :destroy, invoice_state: :non_draft, entry_ids: []
      )

      expect(described_class.create!(**described_class.row_for(operation), state: :prepared).reload.to_operation).to eq(operation)
    end

    it "allows one unresolved operation per invoice, beside any number of terminal ones (§5.3)" do
      operation!(state: "committed")
      operation!(state: "aborted")
      operation!

      aggregate_failures do
        refused { operation! }.to raise_error(ActiveRecord::RecordNotUnique)
        expect { operation!(invoice_id: 11) }.not_to raise_error
      end
    end

    it "keeps one receipt per (invoice, operation)" do
      first = operation!(state: "committed")

      refused { operation!(operation_id: first.operation_id, state: "aborted") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "lets only an aborted receipt go without describing an operation" do
      aggregate_failures do
        expect { operation!(state: "aborted", company_id: nil, kind: nil, invoice_state: nil) }.not_to raise_error
        refused { operation!(invoice_id: 11, kind: nil) }.to raise_error(ActiveRecord::StatementInvalid, /prepared_described/)
      end
    end
  end
end
