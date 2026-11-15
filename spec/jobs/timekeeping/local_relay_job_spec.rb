# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §11.1: the prepared application's relay
# runs on its own queue, so it runs while the `default` worker is not started.
RSpec.describe Timekeeping::LocalRelayJob do
  it "runs on the timekeeping_relay queue" do
    expect(described_class.new.queue_name).to eq("timekeeping_relay")
  end

  it "runs the relay once" do
    relay = instance_double(Timekeeping::LocalRelay, run: Timekeeping::LocalRelay::Result.new(delivered: 0, undelivered: 0))
    allow(Timekeeping::LocalRelay).to receive(:new).and_return(relay)

    described_class.perform_now

    expect(relay).to have_received(:run)
  end
end
