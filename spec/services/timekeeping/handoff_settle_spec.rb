# frozen_string_literal: true

require "rails_helper"

# Settle, step 2 of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5), between close and freeze: every registered invoice operation is
# resolved from its durable outcome and delivered to the outgoing owner under
# the generation it was admitted under, and the fence refuses to freeze until
# that is done. "No pending billing operation crosses the handoff." Run here
# for a rollback, the one handoff whose outgoing owner holds reservations over
# the wire, against the consumer-side fake of Timekeeping (§12.3).
RSpec.describe Timekeeping::HandoffSettle do
  include TimekeepingContracts::ReservationDriver

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:company) { create(:company) }
  let(:invoice_ids) { (700..).each }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  before do
    set_timekeeping_ownership!(generation: 1, owner: "timekeeping", state: "open")
    allow(Rails.error).to receive(:report).and_call_original
  end

  after { expect(fake.violations).to be_empty }

  def entry
    fake.seed_entry(company_id: company.id, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02")
  end

  # §9.2 steps 1 and 2: the intent is open and Timekeeping prepared it.
  def prepared_save
    Timekeeping::InvoiceOperation.open!(invoice_id: invoice_ids.next, company_id: company.id, kind: :save, entry_ids: [entry["id"]])
      .tap { |intent| prepare_in_timekeeping(intent) }
  end

  # §9.2 step 3 committed before the handoff closed admission.
  def succeeded_save
    prepared_save.tap { |intent| ActiveRecord::Base.transaction(requires_new: true) { intent.succeed! } }
  end

  def holding_state(intent)
    fake.holding(intent.entry_ids.first)&.state
  end

  def resolve_calls
    fake.calls.filter_map { |call| [call.operation, call.input.fetch("generation")] if %i[commit abort].include?(call.operation) }
  end

  def ownership
    Timekeeping::Ownership.current.attributes.symbolize_keys.slice(:generation, :owner, :state)
  end

  def close!
    Timekeeping::HandoffFence.call(:close, generation: 1)
  end

  it "resolves a save still pending inside its time limit, and delivers every outcome under the generation it was admitted under" do
    committed, pending = succeeded_save, prepared_save
    close!

    result = described_class.call(generation: 2)

    aggregate_failures do
      expect(result).to eq(Timekeeping::InvoiceOperationWorker::Result.new(
        recovered: { pending.operation_id => "failed" }, delivered: [committed.operation_id, pending.operation_id], undelivered: []
      ))
      expect(resolve_calls).to eq([[:commit, 1], [:abort, 1]])
      expect([holding_state(committed), holding_state(pending)]).to eq([:committed, nil])
      expect(Timekeeping::InvoiceOperation.unsettled).to be_empty
    end
    expect(Timekeeping::HandoffFence.call(:freeze, generation: 2)).to have_attributes(state: "frozen", generation: 2)
  end

  it "fails, retryably, a save that reaches its success record after settle resolved it" do
    intent = prepared_save
    close!
    described_class.call(generation: 2)

    expect { ActiveRecord::Base.transaction(requires_new: true) { intent.succeed! } }
      .to raise_error(Timekeeping::InvoiceOperation::NoLongerPending)
    expect(intent.reload).to have_attributes(state: "failed", delivered_at: be_present)
  end

  it "has nothing to settle at the first cutover, where the legacy owner opened no intent" do
    set_timekeeping_ownership!(generation: 0, owner: "legacy", state: "open")
    Timekeeping::HandoffFence.call(:close, generation: 0)

    expect(described_class.call(generation: 1)).to eq(Timekeeping::InvoiceOperationWorker::Result.new(recovered: {}, delivered: [], undelivered: []))
    expect(fake.calls).to be_empty
    expect(Timekeeping::HandoffFence.call(:freeze, generation: 1).state).to eq("frozen")
  end

  it "keeps the handoff from freezing while a delivery fails, and resumes from settle once the owner answers" do
    intent = succeeded_save
    close!
    WebMock::API.stub_request(:post, %r{/commit\z}).to_raise(Errno::ECONNREFUSED).then.to_rack(fake)

    expect(described_class.call(generation: 2).undelivered).to eq([intent.operation_id])
    expect { Timekeeping::HandoffFence.call(:freeze, generation: 2) }.to raise_error(
      Timekeeping::HandoffFence::Unsettled,
      "Timekeeping handoff: freeze refused, 1 invoice operation(s) not settled (succeeded #{intent.operation_id}); nothing changed"
    )
    expect(ownership).to eq(generation: 2, owner: "timekeeping", state: "closed")

    expect(described_class.call(generation: 2).delivered).to eq([intent.operation_id])
    expect(Timekeeping::HandoffFence.call(:freeze, generation: 2).state).to eq("frozen")
  end

  {
    "before admission closed" => { generation: 1, owner: "timekeeping", state: "open" },
    "after the freeze" => { generation: 2, owner: "timekeeping", state: "frozen" },
    "at another generation" => { generation: 3, owner: "timekeeping", state: "closed" }
  }.each do |name, record|
    it "refuses to run #{name}, and resolves and delivers nothing" do
      intent = prepared_save
      set_timekeeping_ownership!(record)

      expect { described_class.call(generation: 2) }
        .to raise_error(Timekeeping::HandoffFence::OutOfStep, /settle expects generation 2 in state closed/)
      expect(intent.reload).to have_attributes(state: "pending", delivered_at: nil)
      expect(resolve_calls).to eq([])
    end
  end

  # A re-cutover (§10.2 step 6): the outgoing owner is the prepared
  # application, which takes delivery in-process
  # (Timekeeping::LocalReservationClient) and still applies the old
  # generation's commit and abort during settle, only for an operation it
  # registered. No call reaches Timekeeping.
  describe "out of the monolith owner" do
    let(:offsets) { (0..).each }

    before { set_timekeeping_ownership!(generation: 2, owner: "monolith", state: "open") }

    after { expect(fake.calls).to be_empty }

    def held_entry
      Timekeeping::Entry.create!(
        id: TimesheetEntry.maximum(:id).to_i + 1_000 + offsets.next, company_id: company.id, project_id: 7, user_id: 3,
        duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled"
      )
    end

    def open_save(entry_ids)
      Timekeeping::InvoiceOperation.open!(invoice_id: invoice_ids.next, company_id: company.id, kind: :save, entry_ids:)
    end

    # §9.2 steps 1 and 2 under this owner.
    def locally_prepared
      open_save([held_entry.id]).tap do |intent|
        Timekeeping::LocalReservationClient.new.prepare(intent, invoice_state: :draft, resolves: nil)
      end
    end

    def local_state(intent)
      [
        Timekeeping::Reservation.where(invoice_id: intent.invoice_id).pluck(:state),
        Timekeeping::ReservationOperation.find_by(invoice_id: intent.invoice_id, operation_id: intent.operation_id)&.state
      ]
    end

    def close!
      Timekeeping::HandoffFence.call(:close, generation: 2)
    end

    it "resolves the pending save and delivers every outcome under the old generation, so the fence freezes" do
      committed = locally_prepared.tap { |intent| ActiveRecord::Base.transaction(requires_new: true) { intent.succeed! } }
      pending = locally_prepared
      close!

      result = described_class.call(generation: 3)

      aggregate_failures do
        expect(result).to eq(Timekeeping::InvoiceOperationWorker::Result.new(
          recovered: { pending.operation_id => "failed" }, delivered: [committed.operation_id, pending.operation_id], undelivered: []
        ))
        expect([committed, pending].map(&:reload).map(&:generation)).to eq([2, 2])
        expect([local_state(committed), local_state(pending)]).to eq([[["committed"], "committed"], [[], "aborted"]])
        expect(Timekeeping::InvoiceOperation.unsettled).to be_empty
      end
      expect(Timekeeping::HandoffFence.call(:freeze, generation: 3)).to have_attributes(state: "frozen", generation: 3, owner: "monolith")
    end

    it "settles a save whose prepare never ran: recovery records failed and the abort is the no-op receipt (§9.3)" do
      intent = open_save([held_entry.id])
      close!

      expect(described_class.call(generation: 3)).to eq(Timekeeping::InvoiceOperationWorker::Result.new(
        recovered: { intent.operation_id => "failed" }, delivered: [intent.operation_id], undelivered: []
      ))
      expect(local_state(intent)).to eq([[], "aborted"])
      expect(Timekeeping::HandoffFence.call(:freeze, generation: 3).state).to eq("frozen")
    end

    it "keeps a commit of an operation never registered here undelivered as stale-generation, and the fence refuses to freeze" do
      intent = open_save([held_entry.id]).tap { |open| ActiveRecord::Base.transaction(requires_new: true) { open.succeed! } }
      close!

      expect(described_class.call(generation: 3)).to eq(Timekeeping::InvoiceOperationWorker::Result.new(
        recovered: {}, delivered: [], undelivered: [intent.operation_id]
      ))
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(status: 409, type: "stale-generation"), hash_including(context: hash_including(delivery: :commit))
      )
      expect([intent.reload.delivered_at, local_state(intent)]).to eq([nil, [[], nil]])
      expect { Timekeeping::HandoffFence.call(:freeze, generation: 3) }.to raise_error(Timekeeping::HandoffFence::Unsettled, /succeeded #{intent.operation_id}/)
    end
  end
end
