# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §11.1: the invoice operation worker runs
# on its own queue, so it runs while the `default` worker is not started.
RSpec.describe Timekeeping::InvoiceOperationsJob do
  it "runs on the invoice_operations queue" do
    expect(described_class.new.queue_name).to eq("invoice_operations")
  end

  it "runs one sweep of the invoice operation worker" do
    worker = instance_double(Timekeeping::InvoiceOperationWorker, run: :swept)
    allow(Timekeeping::InvoiceOperationWorker).to receive(:new).and_return(worker)

    described_class.perform_now

    expect(worker).to have_received(:run)
  end
end
