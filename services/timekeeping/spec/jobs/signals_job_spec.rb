# frozen_string_literal: true

require "rails_helper"
require "solid_queue"

# Where Timekeeping's polled signal runs (§11.1, §11.3): on the relay's own
# queue, the only one Timekeeping's one worker reads, every 15 seconds.
RSpec.describe SignalsJob do
  let(:configuration) { ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/solid_queue.yml")).fetch("production") }

  it "runs on the timekeeping_relay queue, which the one dedicated worker reads" do
    expect(described_class.new.queue_name).to eq("timekeeping_relay")
    expect(configuration.fetch("workers").map { |worker| worker.fetch("queues") }).to eq(["timekeeping_relay"])
  end

  it "reports the alerts the signals hold now" do
    signals = instance_double(Signals, report!: [])
    allow(Signals).to receive(:new).with(no_args).and_return(signals)

    described_class.perform_now

    expect(signals).to have_received(:report!)
  end

  it "is scheduled every 15 seconds by the dispatcher" do
    (dispatcher,) = configuration.fetch("dispatchers")
    task = dispatcher.dig("recurring_tasks", "signals")
    expect(task.fetch("class").constantize).to eq(described_class)

    schedule = Fugit.parse_cron(task.fetch("schedule"))
    now = Time.utc(2026, 11, 13, 12, 0, 0)
    expect(schedule.next_time(now).to_t - now).to eq(15)
  end
end
