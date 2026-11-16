# frozen_string_literal: true

require "rails_helper"
require "rake"

# The four steps of the billing-handoff proof (docs/architecture/
# timekeeping-soa.md §12.4, "Billing writes during a handoff"), as
# bin/timekeeping-demo billing-handoff runs them: each needs the run's name
# and the seeded users' password, and exits 1 when its check does not hold.
# The handoff step prints the task to run. Timekeeping::BillingHandoffCheck's
# own specs cover the checks.
RSpec.describe "timekeeping:billing_handoff", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(step)
    task = Rake::Task["timekeeping:billing_handoff:#{step}"]
    task.reenable
    task.invoke
  end

  %w[handoff paused refused resumed].each do |step|
    it "#{step} refuses to run without a run name" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV.delete("RUN")

      expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/RUN names the writes of one run/).to_stderr
    end
  end

  it "handoff prints the task the current owner hands over with" do
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    ENV["RUN"] = "spec-run"
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))

    expect { run_task(:handoff) }.to output("timekeeping:rollback\n").to_stdout
  end

  %w[handoff paused].each do |step|
    it "#{step} exits 1, naming the step, while a handoff has admission closed" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run"
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed"))

      expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/billing-handoff proof failed \(#{step}\): .*starts with admission open/).to_stderr
    end
  end

  %w[refused resumed].each do |step|
    it "#{step} exits 1, naming the step, when the run paused no billing write" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run-never-paused"

      expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/billing-handoff proof failed \(#{step}\): no paused billing write for run spec-run-never-paused/).to_stderr
    end
  end
end
