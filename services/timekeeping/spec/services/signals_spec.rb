# frozen_string_literal: true

require "rails_helper"

# Timekeeping's side of the observability table of
# docs/architecture/timekeeping-soa.md §11.3: its relay's lag, alerting above
# 60 s for 5 minutes; stale-generation refusals outside a handoff, and
# reconciliation differences, each alerting on any.
RSpec.describe Signals do
  subject(:signals) { described_class.new(clock: -> { now }) }

  let(:now) { Time.current.change(usec: 0) }
  let(:entry) { entry!(company_id: 1) }
  let(:versions) { (1..).each }

  before { allow(Rails.error).to receive(:report).and_call_original }

  # One outbox snapshot, written `written` ago and delivered `delivered` ago,
  # or not yet.
  def snapshot!(written:, delivered: nil)
    version = versions.next
    OutboxSnapshot.create!(
      entry:, version:, company_id: entry.company_id, request_id: "req-#{version}",
      snapshot: { "entry_id" => entry.id, "version" => version }, created_at: now - written, delivered_at: delivered && now - delivered
    )
  end

  def alert_signals = signals.alerts.map(&:signal)

  # A request as the internal API's controllers see it.
  def request(method, path)
    ActionDispatch::Request.new(Rack::MockRequest.env_for(path, method:, "action_dispatch.request_id" => "req-9"))
  end

  describe "the relay's lag" do
    it "is 0, with nothing behind, while the outbox is drained or empty" do
      expect(signals.read).to have_attributes(relay_lag: 0.0, relay_backlog: 0, relay_lag_sustained: false)

      snapshot!(written: 10.minutes, delivered: 9.minutes)

      expect(signals.read).to have_attributes(relay_lag: 0.0, relay_backlog: 0, relay_lag_sustained: false)
      expect(alert_signals).to be_empty
    end

    it "is how long the oldest undelivered snapshot has waited, and the positions from it to the latest" do
      snapshot!(written: 3.minutes, delivered: 2.minutes)
      snapshot!(written: 90.seconds)
      delivered_later = snapshot!(written: 80.seconds)
      snapshot!(written: 10.seconds)
      delivered_later.update!(delivered_at: now)

      expect(signals.read).to have_attributes(relay_lag: 90.0, relay_backlog: 3)
    end

    it "alerts once the lag has been above 60 s for 5 minutes" do
      snapshot!(written: 6.minutes + 1.second)

      expect(signals.read.relay_lag_sustained).to be(true)
      expect(signals.alerts.sole).to have_attributes(
        signal: :relay_lag, details: { lag: 361.0, backlog: 1 }, message: /the outbox relay has been more than 60 seconds behind for 5 minutes \(361.0 s now/
      )
    end

    it "does not alert while the lag has been above 60 s for less than 5 minutes" do
      snapshot!(written: 5.minutes + 59.seconds)

      expect(signals.read).to have_attributes(relay_lag: 359.0, relay_lag_sustained: false)
      expect(alert_signals).to be_empty
    end

    it "alerts when snapshots delivered one after another kept the lag above 60 s for the whole window" do
      snapshot!(written: 10.minutes, delivered: 3.minutes)
      snapshot!(written: 4.minutes, delivered: 1.minute)
      snapshot!(written: 2.minutes)

      expect(alert_signals).to eq([:relay_lag])
    end

    it "does not alert when the lag dropped below 60 s at any moment of the window" do
      snapshot!(written: 10.minutes, delivered: 4.minutes)
      snapshot!(written: 3.minutes - 1.second) # lagging only from 1:59 before now

      expect(signals.read.relay_lag).to eq(179.0)
      expect(alert_signals).to be_empty
    end

    it "does not alert for a snapshot delivered within 60 s of being written" do
      snapshot!(written: 10.minutes, delivered: 10.minutes - 30.seconds)
      snapshot!(written: 3.minutes)

      expect(alert_signals).to be_empty
    end

    it "stops alerting the moment the backlog is delivered" do
      snapshot!(written: 7.minutes, delivered: 0.seconds)

      expect(alert_signals).to be_empty
    end
  end

  describe "#report!" do
    before { allow(Rails.logger).to receive(:error).and_call_original }

    it "reports and logs each alert that holds, and answers them" do
      snapshot!(written: 6.minutes + 1.second)

      alerts = signals.report!

      expect(alerts.map(&:signal)).to eq([:relay_lag])
      expect(Rails.error).to have_received(:report).with(
        alerts.sole, handled: true, severity: :error, context: { signal: :relay_lag, lag: 361.0, backlog: 1 }
      )
      expect(Rails.logger).to have_received(:error).with(/Timekeeping signal relay_lag: the outbox relay has been more than/)
    end

    it "reports nothing while the relay keeps up" do
      snapshot!(written: 20.seconds)

      expect(signals.report!).to be_empty
      expect(Rails.error).not_to have_received(:report)
    end
  end

  describe ".stale_generation_refused" do
    def refused(slug, ownership)
      Ownership::Refused.new(Problem.new(slug:, status: 409, detail: "X-Ownership-Generation 2 refused: Timekeeping holds #{ownership.summary}"), ownership:)
    end

    it "reports a stale-generation refusal made while the copy was open, with the call and the record it read" do
      ownership = Ownership.new(generation: 3, owner: "timekeeping", state: "open")

      expect(described_class.stale_generation_refused(refused("stale-generation", ownership), request: request("PATCH", "/internal/v1/entries/5"))).to be(true)
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(
          signal: :stale_generation,
          message: "Timekeeping signal stale_generation: PATCH /internal/v1/entries/5 was refused (X-Ownership-Generation 2 refused: " \
            "Timekeeping holds generation 3, owner timekeeping, state open) with no handoff in progress"
        ),
        handled: true, severity: :error,
        context: { signal: :stale_generation, request_id: "req-9", ownership: "generation 3, owner timekeeping, state open" }
      )
    end

    it "reports one made while Timekeeping did not own entries, before the first cutover and after a rollback" do
      [Ownership.new, Ownership.new(generation: 2, owner: "monolith", state: "open")].each do |ownership|
        described_class.stale_generation_refused(refused("stale-generation", ownership), request: request("POST", "/internal/v1/entries"))
      end

      expect(Rails.error).to have_received(:report).twice
    end

    it "reports nothing made while a handoff had the copy closed or frozen" do
      %w[closed frozen].each do |state|
        ownership = Ownership.new(generation: 3, owner: "timekeeping", state:)

        expect(described_class.stale_generation_refused(refused("stale-generation", ownership), request: request("POST", "/internal/v1/entries"))).to be(false)
      end

      expect(Rails.error).not_to have_received(:report)
    end

    it "reports no other refusal" do
      ownership = Ownership.new(generation: 3, owner: "timekeeping", state: "open")

      described_class.stale_generation_refused(refused("ownership-moving", ownership), request: request("POST", "/internal/v1/entries"))

      expect(Rails.error).not_to have_received(:report)
    end
  end

  describe ".reconciliation_differs" do
    it "reports the difference, with each list, against the call that found it" do
      differs = CheckpointReconcile::Differs.new({ entry_differs: [102] })

      described_class.reconciliation_differs(differs, request: request("POST", "/internal/v1/handoff/checkpoint/reconcile"))

      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(
          signal: :reconciliation_differences,
          message: "Timekeeping signal reconciliation_differences: POST /internal/v1/handoff/checkpoint/reconcile: " \
            "Timekeeping checkpoint reconcile: entry_differs 102; abort the handoff"
        ),
        handled: true, severity: :error,
        context: { signal: :reconciliation_differences, request_id: "req-9", lists: { entry_differs: [102] } }
      )
    end
  end
end
