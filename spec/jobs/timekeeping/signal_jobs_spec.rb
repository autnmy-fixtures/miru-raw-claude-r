# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §11.1, §11.3: each dedicated worker
# reads the alerts of the other's work, so a worker that stops is noticed by
# the one still running.
RSpec.describe "Timekeeping signal jobs" do
  let(:signals) { instance_double(Timekeeping::Signals, report!: []) }

  before { allow(Timekeeping::Signals).to receive(:new).and_return(signals) }

  describe Timekeeping::RelaySignalJob do
    it "runs on the invoice operation worker's queue, not the relay's" do
      expect(described_class.new.queue_name).to eq("invoice_operations")
    end

    it "reports the relay's lag alert" do
      described_class.perform_now

      expect(signals).to have_received(:report!).with(%i[relay_lag])
    end
  end

  describe Timekeeping::InvoiceOperationSignalsJob do
    it "runs on the relay worker's queue, not invoice_operations" do
      expect(described_class.new.queue_name).to eq("timekeeping_relay")
    end

    it "reports the ledger's pending and undelivered alerts" do
      described_class.perform_now

      expect(signals).to have_received(:report!).with(%i[pending_operations undelivered_outcomes])
    end
  end
end
