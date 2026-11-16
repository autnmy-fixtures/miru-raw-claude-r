# frozen_string_literal: true

require "rails_helper"
require "rake"

# The four steps of the redelivery proof (docs/architecture/timekeeping-soa.md
# §13 item 6), as bin/timekeeping-demo redelivery runs them: each needs the
# run's name and the seeded users' password, and exits 1 when its check does
# not hold. Timekeeping::RedeliveryCheck's own spec covers the checks.
RSpec.describe "timekeeping:redelivery", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  around do |example|
    saved = ENV.to_h.slice("RUN", "MIRU_SEED_PASSWORD")
    example.run
  ensure
    %w[RUN MIRU_SEED_PASSWORD].each { |key| ENV[key] = saved[key] }
  end

  def run_task(step)
    task = Rake::Task["timekeeping:redelivery:#{step}"]
    task.reenable
    task.invoke
  end

  %w[projected held reordered duplicated].each do |step|
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
        .and output(/redelivery proof failed \(#{step}\): .*runs while Timekeeping owns the entries/).to_stderr
    end
  end
end
