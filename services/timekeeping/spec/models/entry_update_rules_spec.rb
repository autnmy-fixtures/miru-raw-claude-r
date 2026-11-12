# frozen_string_literal: true

require "rails_helper"

# TimesheetEntry's update rules as Timekeeping runs them (§2.1, §6.2): only
# in a writer's context, and worded as the existing application words them.
RSpec.describe "Entry update rules" do
  it "words the locked-edit error as the existing application's TimesheetEntry does" do
    existing = Rails.root.join("../../app/models/timesheet_entry.rb").read

    expect(existing).to include(%("#{Entry::LOCKED_EDIT}"))
  end

  it "never runs on a row a checkpoint loads, even a locked one an employee would be refused (§8 item 1)" do
    entry = entry!(company_id: 1).tap { |row| reservation!(row, invoice_id: 3) }
    entry.caller_role = "employee"
    entry.project_facts = { "id" => 11, "company_id" => 1, "kept" => true, "billable" => true }

    expect(entry.update(note: "Copied", source_metadata: { "mcp_server" => "miru" })).to be(true)
    expect(entry.reload).to have_attributes(note: "Copied", source: "manual")

    entry.note = "Refused"
    expect(entry.save(context: Entry::UPDATE)).to be(false)
    expect(entry.errors.to_hash).to eq(base: [Entry::LOCKED_EDIT])
  end
end
