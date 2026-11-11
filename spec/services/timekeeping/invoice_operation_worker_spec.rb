# frozen_string_literal: true

require "rails_helper"

# The invoice operation worker of docs/architecture/timekeeping-soa.md §11.1:
# recovery over pending intents (§9.2) and delivery of every recorded outcome
# as commit or abort (§9.1, §9.2 step 4), against the consumer-side fake of
# Timekeeping (§12.3). The failure rows of §9.3 it owns: a lost response on
# prepare and on commit, a crash before the invoice commits, Timekeeping down,
# a stale generation.
RSpec.describe Timekeeping::InvoiceOperationWorker do
  include TimekeepingContracts::ReservationDriver

  subject(:worker) { described_class.new(clock: -> { now }) }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:company) { create(:company) }
  let(:now) { Time.current }
  let(:past_the_limit) { now + described_class::SAVE_TIME_LIMIT + 1.second }
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

  def open_intent(entry_ids: [entry["id"]], kind: :save)
    Timekeeping::InvoiceOperation.open!(invoice_id: invoice_ids.next, company_id: company.id, kind:, entry_ids:)
  end

  # §9.2 steps 1-3: intent, prepare, and the invoice transaction recording
  # success.
  def succeeded_save
    open_intent.tap do |intent|
      prepare_in_timekeeping(intent)
      ActiveRecord::Base.transaction(requires_new: true) { intent.succeed! }
    end
  end

  # §9.2 step 4: prepare was answered, then the save failed.
  def failed_save
    open_intent.tap do |intent|
      prepare_in_timekeeping(intent)
      intent.record_failure!
    end
  end

  def holding_states(intent)
    intent.entry_ids.map { |id| fake.holding(id)&.state }
  end

  def resolve_calls
    fake.calls.filter_map { |call| call.operation if %i[commit abort].include?(call.operation) }
  end

  def reported(error_class)
    have_received(:report).with(an_instance_of(error_class), hash_including(handled: true))
  end

  describe "delivery" do
    it "delivers a succeeded outcome as commit and marks it delivered once Timekeeping confirms it" do
      intent = succeeded_save

      result = worker.run

      aggregate_failures do
        expect(result).to eq(described_class::Result.new(recovered: {}, delivered: [intent.operation_id], undelivered: []))
        expect(intent.reload.delivered_at).to be_present
        expect(holding_states(intent)).to eq([:committed])
        expect(resolve_calls).to eq([:commit])
      end
    end

    it "delivers a failed outcome as abort, which drops the save's provisional reservation" do
      intent = failed_save

      worker.run

      expect([intent.reload.delivered_at.present?, holding_states(intent), resolve_calls]).to eq([true, [nil], [:abort]])
    end

    it "carries the intent's generation, its operation id as Idempotency-Key, and a system token for its company" do
      intent = succeeded_save

      worker.run

      call = fake.calls.find { |recorded| recorded.operation == :commit }
      expect(call.input).to eq("generation" => 1)
      expect(call.claims).to include(
        "sub" => "system", "company_id" => company.id, "role" => nil, "writer" => "invoice",
        "timesheet_edit_days" => company.timesheet_edit_days, "actor" => { "type" => "system", "agent_id" => nil }
      )
      expect(call.params).to eq("invoice_id" => intent.invoice_id.to_s, "operation_id" => intent.operation_id)
    end

    it "sends nothing again for an outcome already delivered" do
      succeeded_save
      worker.run

      expect(worker.run.delivered).to eq([])
      expect(resolve_calls).to eq([:commit])
    end

    it "keeps an outcome undelivered while Timekeeping is down, and delivers it on a later sweep (§9.3)" do
      intent = succeeded_save
      WebMock::API.stub_request(:post, %r{/commit\z}).to_raise(Errno::ECONNREFUSED).then.to_rack(fake)

      first = worker.run

      aggregate_failures do
        expect(first.undelivered).to eq([intent.operation_id])
        expect(intent.reload.delivered_at).to be_nil
        expect(holding_states(intent)).to eq([:provisional])
        expect(Rails.error).to reported(Faraday::ConnectionFailed)
      end
      expect(worker.run.delivered).to eq([intent.operation_id])
      expect(holding_states(intent)).to eq([:committed])
    end

    it "resends a commit whose response was lost, and the stored receipt confirms it (§9.3 lost response on commit)" do
      intent = succeeded_save
      fake.lose_next_response(:commit)

      expect(worker.run.undelivered).to eq([intent.operation_id])
      expect(Rails.error).to reported(Faraday::TimeoutError)
      expect(holding_states(intent)).to eq([:committed])

      expect(worker.run.delivered).to eq([intent.operation_id])
      expect(resolve_calls).to eq(%i[commit commit])
    end

    it "keeps an outcome undelivered when Timekeeping refuses its generation as stale" do
      intent = succeeded_save
      fake.generation = 2

      expect(worker.run.undelivered).to eq([intent.operation_id])
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(status: 409, type: "stale-generation"), hash_including(context: hash_including(operation_id: intent.operation_id, delivery: :commit))
      )
      expect(holding_states(intent)).to eq([:provisional])
    end

    it "never marks a commit delivered when Timekeeping holds the operation as aborted" do
      intent = succeeded_save
      reservation_call(:abort, intent, { "generation" => 1 })

      expect(worker.run.undelivered).to eq([intent.operation_id])
      expect(Rails.error).to reported(described_class::OutcomeMismatch)
      expect(intent.reload.delivered_at).to be_nil
    end

    it "delivers every other outcome when one delivery fails" do
      blocked, passing = succeeded_save, failed_save
      fake.fail_next(:commit, status: 503, slug: "ownership-moving", retryable: true)

      result = worker.run

      expect([result.delivered, result.undelivered]).to eq([[passing.operation_id], [blocked.operation_id]])
      expect(Rails.error).to reported(Timekeeping::ReservationClient::Problem)
    end

    it "keeps an outcome undelivered when its company is gone, without holding back the rest" do
      orphaned = Timekeeping::InvoiceOperation.create!(
        operation_id: SecureRandom.uuid, invoice_id: invoice_ids.next, company_id: company.id + 1_000_000, kind: "discard", entry_ids: [], state: "failed", generation: 1
      )
      delivered = failed_save

      result = worker.run

      expect([result.delivered, result.undelivered]).to eq([[delivered.operation_id], [orphaned.operation_id]])
      expect(Rails.error).to reported(ActiveRecord::RecordNotFound)
    end
  end

  describe "recovery (§9.2)" do
    it "resolves an intent pending past the save's time limit as failed, and delivers its abort in the same sweep" do
      intent = open_intent
      prepare_in_timekeeping(intent)

      result = described_class.new(clock: -> { past_the_limit }).run

      aggregate_failures do
        expect(result.recovered).to eq(intent.operation_id => "failed")
        expect(result.delivered).to eq([intent.operation_id])
        expect(intent.reload).to have_attributes(state: "failed", delivered_at: be_present)
        expect(holding_states(intent)).to eq([nil])
      end
    end

    it "delivers abort for an operation whose prepare never reached Timekeeping: a no-op with a receipt (§9.3)" do
      intent = open_intent

      result = described_class.new(clock: -> { past_the_limit }).run

      expect([result.recovered, result.delivered]).to eq([{ intent.operation_id => "failed" }, [intent.operation_id]])
      expect(resolve_calls).to eq([:abort])
    end

    it "leaves a save inside its time limit alone, and sends nothing for it" do
      intent = open_intent
      prepare_in_timekeeping(intent)

      result = worker.run

      expect([result.recovered, result.delivered, result.undelivered]).to eq([{}, [], []])
      expect(intent.reload.state).to eq("pending")
      expect(resolve_calls).to eq([])
    end

    it "never overturns a success the save recorded first" do
      intent = succeeded_save

      result = described_class.new(clock: -> { past_the_limit }).run

      expect(result.recovered).to eq({})
      expect([intent.reload.state, resolve_calls]).to eq(["succeeded", [:commit]])
    end
  end

  describe "owners" do
    it "has nothing to do under the legacy owner when no intent was opened" do
      set_timekeeping_ownership!(generation: 0, owner: "legacy", state: "open")

      expect(worker.run).to eq(described_class::Result.new(recovered: {}, delivered: [], undelivered: []))
    end

    { "legacy" => 0, "monolith" => 2 }.each do |owner, generation|
      it "refuses to deliver under the #{owner} owner, after recovery, and marks nothing delivered" do
        intent = open_intent
        set_timekeeping_ownership!(generation:, owner:, state: "open")

        expect { described_class.new(clock: -> { past_the_limit }).run }
          .to raise_error(described_class::OwnerUnavailable, /owner #{owner} has no reservation provider yet/)
        expect(intent.reload).to have_attributes(state: "failed", delivered_at: nil)
        expect(resolve_calls).to eq([])
      end
    end

    it "refuses to deliver when Timekeeping is not configured here" do
      succeeded_save
      Rails.configuration.x.timekeeping.url = nil

      expect { worker.run }.to raise_error(Timekeeping::ReservationClient::NotConfigured, /TIMEKEEPING_URL/)
    end
  end
end
