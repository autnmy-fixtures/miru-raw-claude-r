# frozen_string_literal: true

require "rails_helper"
require "rake"

# The operator's read of Timekeeping's own signals (§11.3): it prints each
# one, exits non-zero on an alert, and reports nothing itself.
RSpec.describe "timekeeping:signals" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  before do
    Rake::Task["timekeeping:signals"].reenable
    allow(Rails.error).to receive(:report).and_call_original
  end

  def run_task = Rake::Task["timekeeping:signals"].invoke

  it "prints every signal and no alert while everything is quiet" do
    expect { run_task }.to output(<<~OUT).to_stdout
      ownership: generation 0, owner legacy, state open
      relay lag: 0.0 s, 0 position(s) undelivered
      no alerts
    OUT
    expect(Rails.error).not_to have_received(:report)
  end

  it "exits non-zero, naming each alert, without reporting it" do
    entry = entry!(company_id: 1)
    OutboxSnapshot.create!(
      entry:, version: 1, company_id: 1, request_id: "req-1", snapshot: { "entry_id" => entry.id, "version" => 1 }, created_at: 7.minutes.ago
    )

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/relay lag: 4\d\d\.\d s, 1 position\(s\) undelivered \(above the limit for the whole window\)/).to_stdout
      .and output(/ALERT Timekeeping signal relay_lag: the outbox relay has been more than 60 seconds behind/).to_stderr
    expect(Rails.error).not_to have_received(:report)
  end
end
