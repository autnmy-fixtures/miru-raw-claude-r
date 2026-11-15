# frozen_string_literal: true

require "rails_helper"

# What every change of a prepared application's entry writes beside the row
# (docs/architecture/timekeeping-soa.md §3.4, §5.4, §10.1): its audit row and
# its outbox snapshot, as Timekeeping's EntryChange writes them, and nothing
# in timesheet_entries, which stays the projection.
RSpec.describe Timekeeping::LocalEntryChange do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let(:new_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  def entry!(tenant, **attributes)
    Timekeeping::Entry.create!(
      id: new_id, company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
      duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled", **attributes
    )
  end

  def claims(tenant, writer: "web", agent: nil)
    Timekeeping::UserToken.caller_claims(
      user: tenant.employee, company: tenant.company, writer:, project: tenant.project, agent:, request_id: "req-#{writer}"
    )
  end

  it "records a create as its audit row and its snapshot, in the contract's form" do
    entry = entry!(tenant_a)
    audited = entry.to_contract.slice("duration", "work_date", "note", "bill_status", "project_id", "user_id")

    described_class.record!(entry, action: "create", audited_changes: audited, claims: claims(tenant_a))

    audit = entry.audits.sole
    outbox = entry.outbox_snapshots.sole
    aggregate_failures do
      expect(audit).to have_attributes(
        company_id: tenant_a.company.id, action: "create", audited_changes: audited, version: 1,
        actor: "user:#{tenant_a.employee.id}", agent_id: nil, writer: "web", request_id: "req-web"
      )
      expect(outbox).to have_attributes(company_id: tenant_a.company.id, version: 1, request_id: "req-web", delivered_at: nil)
      expect { TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", outbox.snapshot) }.not_to raise_error
      expect(outbox.snapshot).to eq(
        "type" => "timekeeping.entry_snapshot.v1", "entry_id" => new_id, "version" => 1, "company_id" => tenant_a.company.id,
        "data" => entry.to_contract.except("id", "company_id", "version")
      )
      expect(outbox.snapshot.dig("data", "duration")).to eq(90.7)
    end
  end

  it "names the acting agent on the audit row (W4, §6.1)" do
    agent = create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project)
    entry = entry!(tenant_a, agent_id: agent.id)

    described_class.record!(entry, action: "create", audited_changes: { "agent_id" => agent.id }, claims: claims(tenant_a, writer: "agent", agent:))

    expect(entry.audits.sole).to have_attributes(agent_id: agent.id, writer: "agent")
  end

  it "writes no audit row for a change to no audited column, and still writes its snapshot" do
    entry = entry!(tenant_a, version: 4)

    described_class.record!(entry, action: "update", audited_changes: {}, claims: claims(tenant_a, writer: "invoice"))

    aggregate_failures do
      expect(entry.audits).to be_empty
      expect(entry.outbox_snapshots.sole).to have_attributes(version: 4, request_id: "req-invoice")
    end
  end

  it "carries the `locked` its reservations derive as they stand, not as a writer last read them (§7.1)" do
    entry = entry!(tenant_a)
    expect(entry.to_contract).to include("locked" => false)
    Timekeeping::Reservation.create!(
      entry_id: entry.id, invoice_id: 10, company_id: tenant_a.company.id, state: "committed", disposition: "retained", edit_lock: true
    )

    described_class.record!(entry, action: "update", audited_changes: {}, claims: claims(tenant_a))

    expect(entry.outbox_snapshots.sole.snapshot.dig("data", "locked")).to be(true)
  end

  it "keeps one snapshot per entry version" do
    entry = entry!(tenant_a)
    described_class.record!(entry, action: "update", audited_changes: {}, claims: claims(tenant_a))

    expect {
      ActiveRecord::Base.transaction(requires_new: true) do
        described_class.record!(entry, action: "update", audited_changes: {}, claims: claims(tenant_a))
      end
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "writes nothing in timesheet_entries: the projection has one writer (§3.3)" do
    entry = entry!(tenant_a)

    writes = timesheet_entry_writes do
      described_class.record!(entry, action: "create", audited_changes: { "duration" => 90.7 }, claims: claims(tenant_a))
    end

    aggregate_failures do
      expect(writes).to eq([])
      expect(TimesheetEntry.exists?(new_id)).to be(false)
    end
  end
end
