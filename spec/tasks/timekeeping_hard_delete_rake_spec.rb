# frozen_string_literal: true

require "rails_helper"
require "rake"

# The hard-delete-of-a-non-draft part of the failure injection (docs/
# architecture/timekeeping-soa.md §12.4, §9.3), as bin/timekeeping-demo
# hard-delete runs it: it needs the run's name and the seeded users' password, and exits 1 when
# its check does not hold. Timekeeping::HardDeleteCheck's own spec covers the
# checks.
RSpec.describe "timekeeping:hard_delete", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task
    task = Rake::Task["timekeeping:hard_delete"]
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

  it "exits 1 when the legacy owner holds the entries" do
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    ENV["RUN"] = "spec-run"

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/hard-delete proof failed: .*owns the entries with admission open/).to_stderr
  end
end
