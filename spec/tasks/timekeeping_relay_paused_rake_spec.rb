# frozen_string_literal: true

require "rails_helper"
require "rake"

# The two halves of the relay-paused proof (docs/architecture/
# timekeeping-soa.md §13 item 5), as bin/timekeeping-demo relay-paused runs
# them: each needs the run's name and the seeded users' password, and exits 1
# when its check does not hold. Timekeeping::RelayPausedCheck's own spec
# covers the checks.
RSpec.describe "timekeeping:relay_paused", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(half)
    task = Rake::Task["timekeeping:relay_paused:#{half}"]
    task.reenable
    task.invoke
  end

  %w[paused resumed].each do |half|
    it "#{half} refuses to run without a run name" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV.delete("RUN")

      expect { run_task(half) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/RUN names the writes of one run/).to_stderr
    end

    it "#{half} exits 1, naming the half, when the legacy owner holds the entries" do
      ENV["MIRU_SEED_PASSWORD"] = "secret"
      ENV["RUN"] = "spec-run"

      expect { run_task(half) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/relay-paused proof failed \(#{half}\): .*runs while Timekeeping owns the entries/).to_stderr
    end
  end
end
