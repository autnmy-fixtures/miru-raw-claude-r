# frozen_string_literal: true

require "rails_helper"
require "rake"

# The seven steps of the interrupted-and-resumed-handoff proof
# (docs/architecture/timekeeping-soa.md §13 item 6, §10.5), as
# bin/timekeeping-demo interrupted-handoff runs them: each needs the run's
# name and the seeded users' password, and exits 1, naming the step, when its
# check does not hold. The plan step prints the handoff task and the relay
# service. And the drain timeout the proof gives each handoff task
# (DRAIN_TIMEOUT), which reaches its tool. Timekeeping::InterruptedHandoffCheck's
# own specs cover the checks.
RSpec.describe "timekeeping:interrupted_handoff", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD", "DRAIN_TIMEOUT")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD DRAIN_TIMEOUT].each { |key| ENV[key] = saved[key] }
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  def run_step(step) = run_task("timekeeping:interrupted_handoff:#{step}")

  STEPS = %w[plan held paused transferring crashed timed_out resumed].freeze

  STEPS.each do |step|
    it "#{step} refuses to run without a run name" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV.delete("RUN")

      expect { run_step(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/RUN names the writes of one run/).to_stderr
    end
  end

  it "plan prints the handoff task and the relay service the current owner's handoff waits on" do
    ENV["MIRU_SEED_PASSWORD"] = "secret"
    ENV["RUN"] = "spec-run"
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))

    expect { run_step(:plan) }.to output("timekeeping:recutover miru-jobs\n").to_stdout
  end

  %w[plan held].each do |step|
    it "#{step} exits 1, naming the step, while a handoff has admission closed" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run"
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed"))

      expect { run_step(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/interrupted-handoff proof failed \(#{step}\): .*starts with admission open/).to_stderr
    end
  end

  (STEPS - %w[plan held]).each do |step|
    it "#{step} exits 1, naming the step, when the run held nothing" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run-never-held"

      expect { run_step(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/interrupted-handoff proof failed \(#{step}\): no held step for run spec-run-never-held/).to_stderr
    end
  end

  describe "DRAIN_TIMEOUT" do
    # The seeded businesses' recorded disposition, which the first cutover
    # reads first, names invoices these examples do not have.
    before { allow(Timekeeping::RecordedDisposition).to receive(:unlocked_link_invoice_ids).and_return([]) }

    # A tool that records the drain it was built with and stops at once.
    def stub_tool(tool)
      drains = []
      allow(tool).to receive(:new).and_wrap_original do |_original, **options|
        drains << options.fetch(:drain)
        instance_double(tool, call: nil).tap { |double| allow(double).to receive(:call).and_raise(tool::Unresumable, "stub") }
      end
      drains
    end

    {
      "timekeeping:first_cutover" => Timekeeping::FirstCutover,
      "timekeeping:rollback" => Timekeeping::Rollback,
      "timekeeping:recutover" => Timekeeping::Recutover
    }.each do |task, tool|
      it "gives #{task}'s transfer DRAIN_TIMEOUT seconds to drain, and 60 when it is not set" do
        drains = stub_tool(tool)

        ENV["DRAIN_TIMEOUT"] = "600"
        expect { run_task(task) }.to raise_error(SystemExit).and output(/stub/).to_stderr
        ENV.delete("DRAIN_TIMEOUT")
        expect { run_task(task) }.to raise_error(SystemExit).and output(/stub/).to_stderr

        expect(drains.map(&:timeout)).to eq([600, 60])
      end
    end

    it "refuses a DRAIN_TIMEOUT that is not a number of seconds, building no tool" do
      drains = stub_tool(Timekeeping::Rollback)
      ENV["DRAIN_TIMEOUT"] = "soon"

      expect { run_task("timekeeping:rollback") }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/DRAIN_TIMEOUT is the seconds a handoff's transfer waits for its relay to drain, and "soon" is not/).to_stderr
      expect(drains).to be_empty
    end
  end
end
