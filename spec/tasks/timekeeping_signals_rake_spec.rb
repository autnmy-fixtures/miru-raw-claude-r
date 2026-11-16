# frozen_string_literal: true

require "rails_helper"
require "rake"

# The operator's read of the existing application's Timekeeping signals
# (docs/architecture/timekeeping-soa.md §11.3): it prints each one, exits
# non-zero on an alert, and reports nothing itself.
RSpec.describe "timekeeping:signals", type: :model do
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
      invoice operations pending past the limit: 0
      commits or aborts undelivered past the limit: 0
      no alerts
    OUT
    expect(Rails.error).not_to have_received(:report)
  end

  it "exits non-zero, naming each alert, without reporting it" do
    company = create(:company)
    intent = Timekeeping::InvoiceOperation.create!(
      operation_id: SecureRandom.uuid, invoice_id: 700, company_id: company.id, kind: "save", entry_ids: [], generation: 1
    )
    intent.update_columns(created_at: 2.minutes.ago)

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/invoice operations pending past the limit: 1/).to_stdout
      .and output(/ALERT Timekeeping signal pending_operations: .*#{intent.operation_id}/).to_stderr
    expect(Rails.error).not_to have_received(:report)
  end
end
