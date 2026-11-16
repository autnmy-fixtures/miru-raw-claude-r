# frozen_string_literal: true

require "rails_helper"
require "rake"

# The tenant-isolation proof (docs/architecture/timekeeping-soa.md §13 item
# 7), as bin/timekeeping-demo tenant-isolation runs it: it needs the run's
# name and the seeded users' password, and exits 1 when its check does not
# hold. Timekeeping::TenantIsolationCheck's own spec covers the checks.
RSpec.describe "timekeeping:tenant_isolation", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task
    task = Rake::Task["timekeeping:tenant_isolation"]
    task.reenable
    task.invoke
  end

  it "refuses to run without a run name" do
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    ENV.delete("RUN")

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/RUN names the writes of one run/).to_stderr
  end

  it "refuses to run without the seeded users' password" do
    ENV.delete("MIRU_SEED_PASSWORD")
    ENV["RUN"] = "spec-run"

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/MIRU_SEED_PASSWORD is the seeded users' password/).to_stderr
  end

  it "exits 1 while a handoff has closed admission" do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed"))
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    ENV["RUN"] = "spec-run"

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/tenant-isolation proof failed: .*admission is open, under any owner/).to_stderr
  end
end
