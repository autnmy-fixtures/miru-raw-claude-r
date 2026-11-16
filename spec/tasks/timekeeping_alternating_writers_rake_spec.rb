# frozen_string_literal: true

require "rails_helper"
require "rake"

# The alternating-writers proof (docs/architecture/timekeeping-soa.md §12.4),
# as bin/timekeeping-demo alternating-writers runs it: it needs the seeded
# users' password, and exits 1 when a check does not hold.
# Timekeeping::AlternatingWriters's own spec covers the writes and checks.
RSpec.describe "timekeeping:alternating_writers", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("MIRU_SEED_PASSWORD")
    example.run
  ensure
    ENV["MIRU_SEED_PASSWORD"] = saved["MIRU_SEED_PASSWORD"]
  end

  def run_task
    task = Rake::Task["timekeeping:alternating_writers"]
    task.reenable
    task.invoke
  end

  it "refuses to run without the seeded users' password" do
    ENV.delete("MIRU_SEED_PASSWORD")

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/MIRU_SEED_PASSWORD is the seeded users' password/).to_stderr
  end

  it "exits 1, and writes nothing, once a handoff has begun" do
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    Timekeeping::Ownership.current.update!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/Timekeeping alternating writers failed: the alternating writers starts from a freshly seeded demo/).to_stderr
    expect(TimesheetEntry.count).to eq(0)
  end
end
