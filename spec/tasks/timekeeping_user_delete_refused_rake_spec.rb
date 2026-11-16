# frozen_string_literal: true

require "rails_helper"
require "rake"

# The three steps of the user-hard-delete proof (docs/architecture/
# timekeeping-soa.md §12.4), as bin/timekeeping-demo user-delete-refused runs
# them: each needs the run's name and the seeded users' password, and exits 1
# when its check does not hold. Timekeeping::UserDeleteRefusedCheck's own spec
# covers the checks.
RSpec.describe "timekeeping:user_delete_refused", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(step)
    task = Rake::Task["timekeeping:user_delete_refused:#{step}"]
    task.reenable
    task.invoke
  end

  %w[relay paused resumed].each do |step|
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
        .and output(/user-delete proof failed \(#{step}\): .*owns the entries with admission open/).to_stderr
    end
  end

  {
    "cut over to Timekeeping" => "timekeeping-relay",
    "rolled back to the prepared application" => "miru-jobs"
  }.each do |state, service|
    it "relay prints #{service} once #{state}" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch(state))
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run"

      expect { run_task("relay") }.to output("#{service}\n").to_stdout
    end
  end
end
