# frozen_string_literal: true

require "rails_helper"
require "solid_queue"

# The relay's runtime (§11.1, §15.1 D3): its own queue, read by one dedicated
# worker and nothing else, and enqueued by the dispatcher every second.
RSpec.describe OutboxRelayJob do
  let(:configuration) { ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/solid_queue.yml")).fetch("production") }

  it "runs on the timekeeping_relay queue" do
    expect(described_class.new.queue_name).to eq("timekeeping_relay")
  end

  it "runs the relay with this process's configuration" do
    relay = instance_double(OutboxRelay, run: OutboxRelay::Result.new(delivered: 0, undelivered: 0))
    allow(OutboxRelay).to receive(:new).with(no_args).and_return(relay)

    described_class.perform_now

    expect(relay).to have_received(:run)
  end

  it "has one dedicated worker, for the relay's queue only" do
    expect(configuration.fetch("workers")).to eq([{ "queues" => "timekeeping_relay", "threads" => 1, "processes" => 1, "polling_interval" => 0.1 }])
  end

  it "has the dispatcher enqueue the relay every second" do
    (dispatcher,) = configuration.fetch("dispatchers")
    task = dispatcher.dig("recurring_tasks", "outbox_relay")
    expect(task.fetch("class").constantize).to eq(described_class)

    schedule = Fugit.parse_cron(task.fetch("schedule"))
    now = Time.utc(2026, 11, 13, 12, 0, 0)
    expect(schedule.next_time(now).to_t - now).to eq(1)
  end

  it "loads in Solid Queue as that one worker and one dispatcher, which schedules the relay" do
    processes = SolidQueue::Configuration.new(load_from: Rails.root.join("config/solid_queue.yml")).configured_processes
    expect(processes.map(&:kind)).to contain_exactly(:worker, :dispatcher)

    (task,) = processes.find { |process| process.kind == :dispatcher }.attributes.fetch(:recurring_tasks)
    expect([task.key, task.class_name, task.valid?]).to eq(["outbox_relay", "OutboxRelayJob", true])
  end
end
