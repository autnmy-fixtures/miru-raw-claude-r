# frozen_string_literal: true

require "rails_helper"

# A3-A5 (§2.1) as TimesheetEntryPolicy#update? decides them today, row by
# row, with the caller's facts from the token (§6.1).
RSpec.describe EntryPolicy do
  include ActiveSupport::Testing::TimeHelpers

  let(:today) { Date.new(2026, 11, 11) }

  around { |example| travel_to(today.to_time(:utc).change(hour: 12)) { example.run } }

  def entry(bill_status: "unbilled", work_date: today, user_id: 7)
    Entry.new(id: 1, company_id: 1, project_id: 11, user_id:, duration: 30.0, work_date:, bill_status:)
  end

  def claims(role:, sub: "user:7", edit_days: 7)
    { "sub" => sub, "role" => role, "timesheet_edit_days" => edit_days }
  end

  def refusal(entry, claims)
    described_class.authorize!(entry, claims)
    nil
  rescue Problem::Raised => raised
    raised.problem
  end

  it "lets an owner, an admin or the entry's own user change an unbilled entry in the window (A5)" do
    expect(refusal(entry, claims(role: "owner", sub: "user:9"))).to be_nil
    expect(refusal(entry, claims(role: "admin", sub: "user:9"))).to be_nil
    expect(refusal(entry, claims(role: "employee"))).to be_nil
  end

  it "refuses anyone else's entry to a non-privileged caller (A5)" do
    %w[employee book_keeper client].each do |role|
      expect(refusal(entry, claims(role:, sub: "user:9"))).to have_attributes(slug: "forbidden", status: 403, detail: include("(A5)"))
    end
  end

  it "refuses a billed entry to every role, the owner included (A3)" do
    %w[owner admin employee].each do |role|
      expect(refusal(entry(bill_status: "billed"), claims(role:))).to have_attributes(slug: "forbidden", detail: include("(A3)"))
    end
  end

  it "refuses an entry older than the edit window to a non-privileged caller only, the window's last day still open (A4)" do
    expect(refusal(entry(work_date: today - 7), claims(role: "employee"))).to be_nil
    expect(refusal(entry(work_date: today - 8), claims(role: "employee"))).to have_attributes(slug: "forbidden", detail: include("(A4)"))
    expect(refusal(entry(work_date: today - 8), claims(role: "employee", edit_days: 8))).to be_nil
    expect(refusal(entry(work_date: today - 80), claims(role: "admin"))).to be_nil
  end

  it "refuses a caller with no user, which today's policy never has" do
    expect(refusal(entry, claims(role: nil, sub: "system"))).to have_attributes(slug: "forbidden", detail: include("no user"))
  end
end
