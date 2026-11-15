# frozen_string_literal: true

require "rails_helper"

# Which owner answers the entry API's own reads
# (docs/architecture/timekeeping-soa.md §3.3 rule 1). The reads themselves
# are proven through the real entry points in
# spec/requests/timekeeping/entry_reads_spec.rb.
RSpec.describe Timekeeping::EntryReads do
  include_context "with two Timekeeping tenants"

  let(:employee) { tenant_a.employee }
  let(:entry) { unbilled_entry(tenant_a, work_date: Date.new(2026, 11, 2)) }
  let(:november) { Date.new(2026, 11, 1)..Date.new(2026, 11, 30) }
  let(:reads) do
    [
      described_class::List.new(user: employee, company: tenant_a.company, from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30), writer: "web"),
      described_class::Find.new(id: entry.id, company: tenant_a.company, writer: "web"),
      described_class::FindOwn.new(id: entry.id, user: employee, company: tenant_a.company, writer: "cli"),
      described_class::Select.new(ids: [entry.id], user: employee, company: tenant_a.company, writer: "bulk"),
      described_class::Imported.new(company: tenant_a.company, project_ids: [tenant_a.project.id], work_dates: november)
    ]
  end

  it "has a read for every owner, and the same reads for each" do
    expect(described_class::OWNERS.keys).to eq(%w[legacy timekeeping monolith])
    expect(described_class::OWNERS.values.map(&:keys)).to all(eq(reads.map(&:class)))
  end

  it "answers today's queries under the legacy owner" do
    list, find, find_own, select, imported = reads.map { |read| described_class.call(read) }

    expect(list.to_a).to eq([entry])
    expect([find, find_own]).to eq([entry, entry])
    expect { described_class.call(reads[2].with(user: tenant_a.admin)) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(select.to_sql).to eq(TimesheetEntryPolicy::Scope.new(employee, TimesheetEntry).resolve.where(id: [entry.id]).to_sql)
    expect(select.to_a).to eq([entry])
    expect(imported).to eq([])
  end

  it "answers today's duplicate check under the legacy owner: imported, kept entries of kept projects (W5)" do
    unbilled_entry(tenant_a, work_date: Date.new(2026, 11, 3), duration: 90.7, note: "Imported", source: "import")
    unbilled_entry(tenant_a, work_date: Date.new(2026, 11, 3), source: "manual")
    unbilled_entry(tenant_a, work_date: Date.new(2026, 10, 31), source: "import")
    unbilled_entry(tenant_a, work_date: Date.new(2026, 11, 3), source: "import").discard!
    read = reads.last

    expect(described_class.call(read)).to eq([[employee.id, tenant_a.project.id, Date.new(2026, 11, 3), 90.7, "Imported"]])
    tenant_a.project.discard!
    expect(described_class.call(read)).to eq([])
  end

  it "selects under the policy scope (A6): an owner or admin any member's entry, anyone else only their own" do
    theirs = unbilled_entry(tenant_a, user: tenant_a.admin, work_date: Date.new(2026, 11, 2))
    select = reads[3].with(ids: [entry.id, theirs.id])

    expect(described_class.call(select).to_a).to eq([entry])
    expect(described_class.call(select.with(user: tenant_a.admin)).to_a).to contain_exactly(entry, theirs)
  end

  describe "under the monolith owner" do
    let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

    before do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
    end

    # An entry the prepared application holds, as a rollback's checkpoint
    # leaves it (§10.5 step 4); the projection does not hold it.
    def held_entry(tenant, offset:, user: tenant.employee, **attributes)
      Timekeeping::Entry.create!(
        id: first_id + offset, company_id: tenant.company.id, project_id: tenant.project.id, user_id: user.id,
        duration: 90.7, work_date: Date.new(2026, 11, 2), note: "Held", bill_status: "unbilled", **attributes
      )
    end

    # Runs the read and fails if it touched timesheet_entries: what it
    # answers came from the owner's own table.
    def read_owner(read)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?(%("timesheet_entries")) }
      result = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { described_class.call(read) }
      expect(queries).to eq([]), "the read touched the projection"
      result
    end

    it "has the same reads as the other owners" do
      expect(described_class::OWNERS.fetch("monolith").keys).to eq(reads.map(&:class))
    end

    it "answers each read from the prepared application's table, never the projection" do
      projected = entry
      held = held_entry(tenant_a, offset: 0)
      list, find, find_own, select = [
        reads[0], reads[1].with(id: held.id), reads[2].with(id: held.id), reads[3].with(ids: [held.id, projected.id])
      ].map { |read| read_owner(read) }

      expect(TimesheetEntry.where(id: held.id)).to be_empty
      expect([list, select].map { |records| records.map(&:id) }).to eq([[held.id], [held.id]])
      expect([find, find_own].map(&:id)).to eq([held.id, held.id])
      expect { read_owner(reads[1]) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "answers each entry as the contract renders it, read-only, with the locked its reservations derive (§7.1)" do
      held = held_entry(tenant_a, offset: 0, source: "cli", source_metadata: { "client" => "miru-cli" })
      Timekeeping::Reservation.create!(
        entry_id: held.id, invoice_id: 10, company_id: tenant_a.company.id, state: "committed", disposition: "active", edit_lock: true
      )

      found = read_owner(reads[1].with(id: held.id.to_s))

      expect(found).to be_readonly
      expect(found).to have_attributes(
        id: held.id, project_id: tenant_a.project.id, user_id: employee.id, duration: 90.7, note: "Held",
        work_date: Date.new(2026, 11, 2), bill_status: "unbilled", source: "cli", locked: true,
        source_metadata: { "client" => "miru-cli" }
      )
      expect(found.attributes.except("id")).to eq(Timekeeping::Gateway::Remote.record(held.reload.to_contract).attributes.except("id"))
    end

    it "lists the user's kept entries in the dates, newest work date first, with what the list renders loaded" do
      older = held_entry(tenant_a, offset: 0, work_date: Date.new(2026, 11, 2))
      newer = held_entry(tenant_a, offset: 1, work_date: Date.new(2026, 11, 4))
      same_day = held_entry(tenant_a, offset: 2, work_date: Date.new(2026, 11, 4))
      held_entry(tenant_a, offset: 3, discarded_at: Time.current)
      held_entry(tenant_a, offset: 4, work_date: Date.new(2026, 10, 31))
      held_entry(tenant_a, offset: 5, user: tenant_a.admin)
      held_entry(tenant_b, offset: 6, user: tenant_b.employee)

      listed = read_owner(reads[0])

      expect(listed.map(&:id)).to eq([newer.id, same_day.id, older.id])
      expect(listed.map { |record| record.association(:project).loaded? && record.project.association(:client).loaded? }).to all(be(true))
      expect(listed.first.snippet).to include(id: newer.id, project: tenant_a.project.name, client: tenant_a.client.name)
    end

    it "answers today's not-found for an entry it does not hold kept in the company (§6.3)" do
      discarded = held_entry(tenant_a, offset: 0, discarded_at: Time.current)
      foreign = held_entry(tenant_b, offset: 1, user: tenant_b.employee)

      [discarded.id, foreign.id, entry.id, "not-an-id", 0].each do |id|
        expect { read_owner(reads[1].with(id:)) }.to raise_error(ActiveRecord::RecordNotFound, /'id'=#{id}/)
      end
    end

    it "finds only the caller's own entry for W3, whatever the caller's role (A7)" do
      held = held_entry(tenant_a, offset: 0)

      expect(read_owner(reads[2].with(id: held.id)).id).to eq(held.id)
      expect { read_owner(reads[2].with(id: held.id, user: tenant_a.admin)) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "selects under the policy scope (A6): an owner or admin any member's kept entry, anyone else only their own" do
      mine = held_entry(tenant_a, offset: 0)
      theirs = held_entry(tenant_a, offset: 1, user: tenant_a.admin)
      discarded = held_entry(tenant_a, offset: 2, discarded_at: Time.current)
      foreign = held_entry(tenant_b, offset: 3, user: tenant_b.employee)
      select = reads[3].with(ids: [theirs.id, mine.id, discarded.id, foreign.id, "not-an-id"].map(&:to_s))

      expect(read_owner(select).map(&:id)).to eq([mine.id])
      expect(read_owner(select.with(user: tenant_a.admin)).map(&:id)).to eq([mine.id, theirs.id])
    end

    it "answers W5's duplicate check: imported, kept entries of kept projects in the dates" do
      held_entry(tenant_a, offset: 0, work_date: Date.new(2026, 11, 3), duration: 90.7, note: "Imported", source: "import")
      held_entry(tenant_a, offset: 1, work_date: Date.new(2026, 11, 3), source: "manual")
      held_entry(tenant_a, offset: 2, work_date: Date.new(2026, 10, 31), source: "import")
      held_entry(tenant_a, offset: 3, work_date: Date.new(2026, 11, 3), source: "import", discarded_at: Time.current)
      held_entry(tenant_b, offset: 4, user: tenant_b.employee, work_date: Date.new(2026, 11, 3), source: "import")
      read = reads.last

      expect(read_owner(read)).to eq([[employee.id, tenant_a.project.id, Date.new(2026, 11, 3), 90.7, "Imported"]])
      tenant_a.project.discard!
      expect(read_owner(read)).to eq([])
    end
  end
end
