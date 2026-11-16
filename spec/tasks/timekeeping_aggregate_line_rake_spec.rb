# frozen_string_literal: true

require "rails_helper"
require "rake"

# The three steps of the aggregate-line proof (docs/architecture/
# timekeeping-soa.md §12.4, F3), as bin/timekeeping-demo aggregate-line runs
# them: each needs the run's name and the seeded users' password, and exits 1
# when its check does not hold. Timekeeping::AggregateLineCheck's own spec
# covers the checks.
RSpec.describe "timekeeping:aggregate_line", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(step)
    task = Rake::Task["timekeeping:aggregate_line:#{step}"]
    task.reenable
    task.invoke
  end

  %w[held outage restored].each do |step|
    it "#{step} refuses to run without a run name" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV.delete("RUN")

      expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/RUN names the writes of one run/).to_stderr
    end

    it "#{step} exits 1, naming the step, when the legacy owner holds the entries" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run"

      expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/aggregate-line proof failed \(#{step}\): .*owns the entries with admission open/).to_stderr
    end
  end
end
