# frozen_string_literal: true

require "rails_helper"

# The existing application's side of the observability table of
# docs/architecture/timekeeping-soa.md §11.3: the local relay's lag, invoice
# operations pending past 60 s, commits and aborts undelivered past 60 s, and
# stale-generation refusals outside a handoff, each with the alert the table
# names.
RSpec.describe Timekeeping::Signals do
  include_context "with two Timekeeping tenants"

  subject(:signals) { described_class.new(clock: -> { now }) }

  let(:now) { Time.current.change(usec: 0) }
  let(:entry) do
    Timekeeping::Entry.create!(
      id: TimesheetEntry.maximum(:id).to_i + 1_000, company_id: tenant_a.company.id, project_id: tenant_a.project.id,
      user_id: tenant_a.employee.id, duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled"
    )
  end
  let(:versions) { (1..).each }

  before { allow(Rails.error).to receive(:report).and_call_original }

  # One outbox snapshot, written `written` ago and delivered `delivered` ago,
  # or not yet.
  def snapshot!(written:, delivered: nil)
    version = versions.next
    Timekeeping::OutboxSnapshot.create!(
      entry:, version:, company_id: entry.company_id, request_id: "req-#{version}",
      snapshot: { "entry_id" => entry.id, "version" => version }, created_at: now - written, delivered_at: delivered && now - delivered
    )
  end

  # One ledger intent in `state`, opened `opened` ago, whose outcome was last
  # changed `changed` ago.
  def intent!(state:, opened:, changed: opened, delivered: false)
    Timekeeping::InvoiceOperation.create!(
      operation_id: SecureRandom.uuid, invoice_id: 700 + Timekeeping::InvoiceOperation.count, company_id: tenant_a.company.id,
      kind: "save", entry_ids: [], generation: 1, state:, delivered_at: (now if delivered)
    ).tap { |intent| intent.update_columns(created_at: now - opened, updated_at: now - changed) }
  end

  def alert_signals(only = described_class::POLLED) = signals.alerts(only).map(&:signal)

  describe "the local relay's lag" do
    it "is 0, with nothing behind, while the outbox is drained" do
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
      expect(alert_signals).to eq([:relay_lag])
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
  end

  describe "invoice operations pending past 60 s" do
    it "alerts for any, naming each" do
      old = intent!(state: "pending", opened: 61.seconds)
      intent!(state: "pending", opened: 59.seconds)

      expect(signals.read.pending_operations).to eq([old.operation_id])
      expect(signals.alerts.sole).to have_attributes(signal: :pending_operations, details: { operation_ids: [old.operation_id] })
    end
  end

  describe "commits and aborts undelivered past 60 s" do
    it "alerts for any outcome recorded more than 60 s ago and still undelivered, by its delivery" do
      commit = intent!(state: "succeeded", opened: 5.minutes, changed: 2.minutes)
      abort = intent!(state: "failed", opened: 3.minutes, changed: 61.seconds)
      intent!(state: "failed", opened: 3.minutes, changed: 30.seconds)
      intent!(state: "succeeded", opened: 5.minutes, changed: 2.minutes, delivered: true)

      expect(signals.read.undelivered_outcomes).to eq([[commit.operation_id, :commit], [abort.operation_id, :abort]])
      expect(alert_signals).to eq([:undelivered_outcomes])
    end

    it "counts a pending intent as pending, not undelivered" do
      intent!(state: "pending", opened: 2.minutes)

      expect(signals.read.undelivered_outcomes).to be_empty
    end
  end

  describe "#report!" do
    before do
      snapshot!(written: 6.minutes + 1.second)
      intent!(state: "pending", opened: 2.minutes)
      allow(Rails.logger).to receive(:error).and_call_original
    end

    it "reports and logs each alert of the signals it is given" do
      alerts = signals.report!(described_class::INVOICE_OPERATIONS)

      expect(alerts.map(&:signal)).to eq([:pending_operations])
      expect(Rails.error).to have_received(:report).with(
        alerts.sole, handled: true, severity: :error, context: hash_including(signal: :pending_operations)
      )
      expect(Rails.logger).to have_received(:error).with(/Timekeeping signal pending_operations: 1 invoice operation\(s\) pending/)
    end

    it "reads every polled signal by default" do
      expect(signals.report!.map(&:signal)).to eq(%i[relay_lag pending_operations])
    end

    it "reports nothing while every signal is quiet" do
      Timekeeping::OutboxSnapshot.update_all(delivered_at: now)
      Timekeeping::InvoiceOperation.update_all(state: "failed", delivered_at: now)

      expect(signals.report!).to be_empty
      expect(Rails.error).not_to have_received(:report)
    end
  end

  describe ".stale_generation_refused" do
    def problem(slug)
      Timekeeping::LocalReservationClient.problem(slug, 409, detail: "operation op-1 carries generation 1")
    end

    it "reports a stale-generation refusal while this copy of the ownership record is open" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
      refused = problem("stale-generation")

      expect(described_class.stale_generation_refused(refused, source: "Timekeeping::ReservationClient")).to be(refused)
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(signal: :stale_generation, message: /Timekeeping::ReservationClient was refused \(409 stale-generation/),
        handled: true, severity: :error,
        context: { signal: :stale_generation, source: "Timekeeping::ReservationClient", ownership: "generation 1, owner timekeeping, state open" }
      )
    end

    it "reports nothing while a handoff has this copy closed or frozen" do
      %w[closed frozen].each do |state|
        set_timekeeping_ownership!(generation: 2, owner: "timekeeping", state:)

        described_class.stale_generation_refused(problem("stale-generation"), source: "Timekeeping::ReservationClient")
      end

      expect(Rails.error).not_to have_received(:report)
    end

    it "reports no other problem" do
      described_class.stale_generation_refused(problem("idempotency-conflict"), source: "Timekeeping::ReservationClient")

      expect(Rails.error).not_to have_received(:report)
    end
  end

  describe "where stale-generation refusals are seen" do
    it "reports one Timekeeping answers over HTTP outside a handoff" do
      fake = TimekeepingContracts::FakeTimekeeping.new(generation: 5).install!
      client = Timekeeping::ReservationClient.new(url: TimekeepingContracts::FakeTimekeeping::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY)
      set_timekeeping_ownership!(generation: 4, owner: "timekeeping", state: "open")
      intent = Timekeeping::InvoiceOperation.new(
        operation_id: SecureRandom.uuid, invoice_id: 812, company_id: tenant_a.company.id, kind: "save", entry_ids: [], generation: 4
      )

      expect { client.abort(intent) }.to raise_error(Timekeeping::ReservationClient::Problem, /stale-generation/)
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(signal: :stale_generation), hash_including(context: hash_including(source: "Timekeeping::ReservationClient"))
      )
      expect(fake.violations).to be_empty
    end

    it "reports one the prepared application refuses as the monolith owner, outside a handoff" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
      intent = Timekeeping::InvoiceOperation.new(
        operation_id: SecureRandom.uuid, invoice_id: 812, company_id: tenant_a.company.id, kind: "save", entry_ids: [], generation: 1
      )

      expect { Timekeeping::LocalReservationClient.new.abort(intent) }.to raise_error(Timekeeping::ReservationClient::Problem, /stale-generation/)
      expect(Rails.error).to have_received(:report).with(
        an_object_having_attributes(signal: :stale_generation),
        hash_including(context: hash_including(source: "Timekeeping::LocalReservationClient", ownership: "generation 2, owner monolith, state open"))
      )
    end

    it "does not report the settle step's refusal while a handoff out of the monolith owner has admission closed" do
      set_timekeeping_ownership!(generation: 3, owner: "monolith", state: "closed")
      intent = Timekeeping::InvoiceOperation.new(
        operation_id: SecureRandom.uuid, invoice_id: 812, company_id: tenant_a.company.id, kind: "save", entry_ids: [], generation: 2
      )

      expect { Timekeeping::LocalReservationClient.new.commit(intent) }.to raise_error(Timekeeping::ReservationClient::Problem, /stale-generation/)
      expect(Rails.error).not_to have_received(:report)
    end
  end
end
