# frozen_string_literal: true

require "rails_helper"
require "rake"

# The reservation-protocol part of the failure injection (docs/architecture/
# timekeeping-soa.md §12.4, §9.3), as bin/timekeeping-demo
# reservation-failures runs its two steps: each needs the run's name and the
# seeded users' password, and exits 1 when its check does not hold.
# Timekeeping::ReservationFailuresCheck's own spec covers the checks.
RSpec.describe "timekeeping:reservation_failures", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(step)
    task = Rake::Task["timekeeping:reservation_failures:#{step}"]
    task.reenable
    task.invoke
  end

  %w[paused resumed].each do |step|
    describe step do
      it "refuses to run without a run name" do
        ENV["MIRU_SEED_PASSWORD"] = "secret"
        ENV.delete("RUN")

        expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
          .and output(/RUN names the writes of one run/).to_stderr
      end

      it "refuses to run without the seeded users' password" do
        ENV.delete("MIRU_SEED_PASSWORD")
        ENV["RUN"] = "spec-run"

        expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
          .and output(/MIRU_SEED_PASSWORD is the seeded users' password/).to_stderr
      end

      it "exits 1 when the legacy owner holds the entries" do
        ENV["MIRU_SEED_PASSWORD"] = "secret"
        ENV["RUN"] = "spec-run"

        expect { run_task(step) }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
          .and output(/reservation-failures proof failed \(#{step}\): .*owns the entries with admission open/).to_stderr
      end
    end
  end
end
