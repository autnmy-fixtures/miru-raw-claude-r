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

  it "refuses to deliver under the monolith owner, which has no reservation provider yet, after resolving the pending intent" do
    intent = prepared_save
    set_timekeeping_ownership!(generation: 3, owner: "monolith", state: "closed")

    expect { described_class.call(generation: 3) }
      .to raise_error(Timekeeping::InvoiceOperationWorker::OwnerUnavailable, /owner monolith/)
    expect(intent.reload).to have_attributes(state: "failed", delivered_at: nil)
    expect { Timekeeping::HandoffFence.call(:freeze, generation: 3) }.to raise_error(Timekeeping::HandoffFence::Unsettled, /failed #{intent.operation_id}/)
  end
end
