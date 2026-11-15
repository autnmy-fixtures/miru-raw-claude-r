# frozen_string_literal: true

require "rails_helper"

# The gateway's `monolith` owner (docs/architecture/timekeeping-soa.md §3.1,
# §10.5): the prepared application's single-entry writes over its own entry
# table. Each command is decided by today's rules (§2.1, §2.2) and the
# caller is checked again on the entry as held (A3-A5, §6.2); the entry is
# saved as its next version with its audit and outbox rows, and nothing is
# written to timesheet_entries, which stays the projection (§3.2) until the
# local relay delivers the outbox to it.
RSpec.describe Timekeeping::Gateway::Local, type: :model do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let(:gateway) { Timekeeping::Gateway }
  let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  around do |example|
    example.run
  ensure
    Current.reset
    Rails.event.clear_context
  end

  before do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
    advance_local_entry_ids!
    act_as(tenant_a.employee, tenant_a)
  end

  def act_as(user, tenant)
    Current.user = user
    Current.company = tenant.company
  end

  # An entry the prepared application holds, as a rollback's checkpoint
  # leaves it (§10.5 step 4).
  def held_entry(tenant, offset: 0, user: tenant.employee, **attributes)
    Timekeeping::Entry.create!(
      id: first_id + offset, company_id: tenant.company.id, project_id: tenant.project.id, user_id: user.id,
      duration: 60.0, work_date: Date.current, note: "Before", bill_status: "unbilled", **attributes
    )
  end

  # The entry as the controller hands it to the gateway: the owner's read.
  def read(entry) = Timekeeping::Gateway::Remote.record(entry.reload.to_contract)

  def create_command(tenant = tenant_a, user: tenant.employee, writer: "web", **attributes)
    gateway::CreateEntry.new(
      project: tenant.project, user:, writer:,
      attributes: ActionController::Parameters.new(duration: "90.7", work_date: "2026-11-02", note: "Local", **attributes).permit!
    )
  end

  def update_command(entry, tenant = tenant_a, project: tenant.project, **attributes)
    gateway::UpdateEntry.new(entry: read(entry), project:, writer: "cli", attributes:)
  end

  # Runs the command and answers its result, failing if anything wrote the
  # projection.
  def written(&command)
    result = nil
    writes = timesheet_entry_writes { result = gateway.call(command.call) }
    expect(writes).to eq([]), "the monolith owner wrote the projection"
    result
  end

  def reserve!(entry, edit_lock: true)
    Timekeeping::Reservation.create!(
      entry_id: entry.id, invoice_id: 10, company_id: entry.company_id, state: "committed", disposition: "active", edit_lock:
    )
  end

  def expect_snapshot(entry)
    snapshot = entry.outbox_snapshots.order(:version).last.snapshot
    expect { TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", snapshot) }.not_to raise_error
    expect(snapshot).to eq(
      "type" => "timekeeping.entry_snapshot.v1", "entry_id" => entry.id, "version" => entry.version,
      "company_id" => entry.company_id, "data" => entry.reload.to_contract.except("id", "company_id", "version")
    )
  end

  it "runs only the single-entry commands so far" do
    expect(described_class::HANDLERS.keys).to contain_exactly(gateway::CreateEntry, gateway::UpdateEntry, gateway::DiscardEntry)
  end

  it "records the columns `audited` records on TimesheetEntry today, and writes every column the two tables share but its own" do
    expect(described_class::AUDITED).to match_array(%w[
      duration work_date note bill_status review_status project_id user_id agent_id
      source source_metadata proof_url proof_metadata discarded_at
    ])
    expect(described_class::WRITTEN).to match_array(%w[
      agent_id bill_status discarded_at duration external_run_id external_session_id note project_id
      proof_metadata proof_url review_status source source_metadata user_id work_date
    ])
  end

  describe "CreateEntry" do
    it "writes the entry in its tenant as version 1, with its create audit and its snapshot, and answers it for today's rendering" do
      Rails.event.set_context(request_id: "req-local")

      created = written { create_command }

      entry = Timekeeping::Entry.find(created.id)
      aggregate_failures do
        expect(entry).to have_attributes(
          company_id: tenant_a.company.id, project_id: tenant_a.project.id, user_id: tenant_a.employee.id, agent_id: nil,
          duration: 90.7, work_date: Date.new(2026, 11, 2), note: "Local", bill_status: "unbilled",
          review_status: "not_required", source: "manual", version: 1
        )
        expect(entry.audits.sole).to have_attributes(
          action: "create", version: 1, company_id: tenant_a.company.id, actor: "user:#{tenant_a.employee.id}",
          writer: "web", request_id: "req-local",
          audited_changes: entry.to_contract.slice(*described_class::AUDITED)
        )
        expect(entry.outbox_snapshots.sole).to have_attributes(version: 1, request_id: "req-local", delivered_at: nil)
        expect_snapshot(entry)

        expect(created).to be_readonly
        expect(created).to have_attributes(id: entry.id, duration: 90.7, bill_status: "unbilled", version: 1, locked: false)
        expect(created.snippet).to include(project: tenant_a.project.name, client: tenant_a.client.name, team_member: tenant_a.employee.full_name)
        expect(TimesheetEntry.where(id: entry.id)).to be_empty
      end
    end

    it "sets the command's project and user over any the attributes name, as the legacy owner does" do
      created = written { create_command(project_id: tenant_b.project.id, user_id: tenant_b.employee.id) }

      expect(Timekeeping::Entry.find(created.id)).to have_attributes(
        company_id: tenant_a.company.id, project_id: tenant_a.project.id, user_id: tenant_a.employee.id
      )
    end

    it "applies today's normalization: the source rewrite, the metadata and the bill status of a non-billable project" do
      project = create(:project, client: tenant_a.client, billable: false)
      command = gateway::CreateEntry.new(
        project:, user: tenant_a.employee, writer: "cli",
        attributes: {
          duration: "30", work_date: "2026-11-02", source: "CLI",
          source_metadata: { "mcp_server" => "  miru  ", "other" => "dropped" }, proof_metadata: { "blank" => " ", "kept" => 1 }
        }
      )

      entry = Timekeeping::Entry.find(written { command }.id)

      expect(entry).to have_attributes(
        source: "mcp", source_metadata: { "mcp_server" => "miru" }, proof_metadata: { "kept" => 1 }, bill_status: "non_billable"
      )
    end

    it "acts as the agent for an agent's entry: pending review, and the agent named on the audit row (W4, A10)" do
      agent = create(:agent, company: tenant_a.company, user: tenant_a.employee, default_project: tenant_a.project)

      created = written { create_command(writer: "agent", source: "automation", agent:) }

      entry = Timekeeping::Entry.find(created.id)
      expect(entry).to have_attributes(agent_id: agent.id, review_status: "pending_review", source: "automation")
      expect(entry.audits.sole).to have_attributes(agent_id: agent.id, writer: "agent")
      expect(created.agent).to eq(agent)
    end

    it "emits today's observability event for the new entry" do
      allow(Rails.event).to receive(:notify).and_call_original

      created = written { create_command }

      expect(Rails.event).to have_received(:notify).with(an_instance_of(TimesheetEntries::Created)) { |event|
        expect(event.record.id).to eq(created.id)
      }
    end

    it "is the system actor when there is no Current.user, as the model's own checks read today" do
      Current.user = nil

      created = written { create_command }

      expect(Timekeeping::Entry.find(created.id).audits.sole.actor).to eq("system")
    end

    {
      "a duration over today's maximum" => [{ duration: "6000001" }, "Duration must be less than or equal to 6000000"],
      "an entry created billed" => [{ bill_status: "billed" }, I18n.t("errors.create_billed_entry")]
    }.each do |case_name, (attributes, message)|
      it "refuses #{case_name} with today's RecordInvalid, and writes nothing" do
        expect { gateway.call(create_command(**attributes)) }.to raise_error(ActiveRecord::RecordInvalid) { |error|
          expect(error.record).to be_a(TimesheetEntry)
          expect(error.record.errors.full_messages.first).to end_with(message)
        }
        expect([Timekeeping::Entry, Timekeeping::EntryAudit, Timekeeping::OutboxSnapshot].map(&:count)).to all(eq(0))
      end
    end

    it "refuses another company's agent, as today's model does" do
      agent = create(:agent, company: tenant_b.company, user: tenant_b.employee, default_project: tenant_b.project)

      expect { gateway.call(create_command(writer: "agent", agent:)) }
        .to raise_error(ActiveRecord::RecordInvalid, /Agent must belong to the same company/)
      expect(Timekeeping::Entry.count).to eq(0)
    end
  end

  describe "UpdateEntry" do
    let!(:entry) { held_entry(tenant_a) }

    it "saves the change as the next version, with its audit row of [before, after] and its snapshot" do
      Rails.event.set_context(request_id: "req-update")

      updated = written { update_command(entry, duration: "45", note: "After") }

      entry.reload
      aggregate_failures do
        expect(entry).to have_attributes(duration: 45.0, note: "After", version: 2)
        expect(entry.audits.sole).to have_attributes(
          action: "update", version: 2, actor: "user:#{tenant_a.employee.id}", writer: "cli", request_id: "req-update",
          audited_changes: { "duration" => [60.0, 45.0], "note" => ["Before", "After"] }
        )
        expect_snapshot(entry)
        expect(updated).to be_readonly
        expect(updated).to have_attributes(id: entry.id, note: "After", version: 2)
      end
    end

    it "moves the entry to the command's project, then applies the attributes, as the legacy owner does" do
      target = create(:project, client: tenant_a.client, billable: true)

      written { update_command(entry, project: target) }
      expect(entry.reload.project_id).to eq(target.id)

      written { update_command(entry, project: target, project_id: tenant_a.project.id) }
      expect(entry.reload.project_id).to eq(tenant_a.project.id)
    end

    it "writes nothing for an update that changes nothing, and answers the entry as it stands" do
      updated = written { update_command(entry, note: "Before") }

      expect(updated).to have_attributes(id: entry.id, version: 1)
      expect([entry.audits.count, entry.outbox_snapshots.count, entry.reload.version]).to eq([0, 0, 1])
    end

    it "lets an employee mark their own entry billed, as today (A11)" do
      written { update_command(entry, bill_status: "billed") }

      expect(entry.reload.bill_status).to eq("billed")
    end

    describe "the edit lock, from the entry's reservations (L1, §7.1)" do
      before { reserve!(entry) }

      it "refuses an employee with today's message, and writes nothing" do
        expect { gateway.call(update_command(entry, note: "After")) }
          .to raise_error(ActiveRecord::RecordInvalid, /Cannot edit a locked timesheet entry. Please contact admin./)
        expect(entry.reload).to have_attributes(note: "Before", version: 1)
        expect(entry.outbox_snapshots).to be_empty
      end

      it "lets an admin edit, and the snapshot still carries the lock" do
        act_as(tenant_a.admin, tenant_a)

        written { update_command(entry, note: "After") }

        expect(entry.reload.note).to eq("After")
        expect(entry.outbox_snapshots.sole.snapshot.dig("data", "locked")).to be(true)
      end

      it "does not lock an entry whose reservation holds no edit lock" do
        Timekeeping::Reservation.update_all(edit_lock: false)

        written { update_command(entry, note: "After") }

        expect(entry.reload.note).to eq("After")
      end
    end

    describe "the caller, checked again on the entry as held (A3-A5, §6.2)" do
      it "refuses an entry billed after the controller read it, with today's policy refusal" do
        command = update_command(entry, note: "After")
        entry.update!(bill_status: "billed")

        expect { gateway.call(command) }.to raise_error(Pundit::NotAuthorizedError) { |error| expect(error.query).to eq(:update?) }
        expect(entry.reload.note).to eq("Before")
      end

      it "refuses an employee outside the company's edit window, and lets an admin through" do
        entry.update!(work_date: (tenant_a.company.timesheet_edit_days + 1).days.ago.to_date)

        expect { gateway.call(update_command(entry, note: "After")) }.to raise_error(Pundit::NotAuthorizedError)

        act_as(tenant_a.admin, tenant_a)
        written { update_command(entry, note: "After") }
        expect(entry.reload.note).to eq("After")
      end

      it "refuses an employee another user's entry" do
        act_as(member_of(tenant_a.company, role: :employee), tenant_a)

        expect { gateway.call(update_command(entry, note: "After")) }.to raise_error(Pundit::NotAuthorizedError)
      end

      it "refuses a caller with no user: no writer sends one" do
        Current.user = nil

        expect { gateway.call(update_command(entry, note: "After")) }.to raise_error(Pundit::NotAuthorizedError)
      end
    end

    it "takes the entry FOR UPDATE, so it serializes with reservation changes (§9.4)" do
      statements = []
      collect = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?('"timekeeping_entries"') }

      command = update_command(entry, note: "After")
      ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { gateway.call(command) }

      expect(statements.first).to match(/\ASELECT .* FROM "timekeeping_entries" WHERE .*FOR UPDATE\z/m)
    end

    it "answers today's not-found for another company's entry, and for a discarded one (§6.3)" do
      other = held_entry(tenant_b, offset: 1)
      act_as(tenant_b.employee, tenant_b)
      foreign = gateway::UpdateEntry.new(entry: read(entry), project: tenant_b.project, writer: "web", attributes: { note: "Taken" })

      expect { gateway.call(foreign) }.to raise_error(ActiveRecord::RecordNotFound, /'id'=#{entry.id}/)
      expect(entry.reload.note).to eq("Before")

      other.update!(discarded_at: Time.current)
      expect { gateway.call(update_command(other, tenant_b, note: "After")) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "DiscardEntry" do
    let!(:entry) { held_entry(tenant_a) }

    it "discards the entry as its next version, with its audit row and its snapshot" do
      discarded = written { gateway::DiscardEntry.new(entry: read(entry), writer: "mobile") }

      entry.reload
      aggregate_failures do
        expect(entry.discarded_at).to be_present
        expect(entry.version).to eq(2)
        expect(entry.audits.sole).to have_attributes(action: "update", writer: "mobile")
        expect(entry.audits.sole.audited_changes.keys).to eq(["discarded_at"])
        expect_snapshot(entry)
        expect(discarded).to be_discarded
      end
    end

    it "lets an employee discard their own locked entry, as today's discard! validates nothing" do
      reserve!(entry)

      written { gateway::DiscardEntry.new(entry: read(entry), writer: "web") }

      expect(entry.reload.discarded_at).to be_present
    end

    it "refuses a billed entry with today's policy refusal" do
      entry.update!(bill_status: "billed")

      expect { gateway.call(gateway::DiscardEntry.new(entry: read(entry), writer: "web")) }
        .to raise_error(Pundit::NotAuthorizedError) { |error| expect(error.query).to eq(:destroy?) }
      expect(entry.reload.discarded_at).to be_nil
    end

    it "answers today's not-found for an entry already discarded" do
      command = gateway::DiscardEntry.new(entry: read(entry), writer: "web")
      gateway.call(command)

      expect { gateway.call(command) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "refuses the commands it does not run yet, and writes nothing" do
    entry = held_entry(tenant_a)
    command = gateway::BulkDiscard.new(entries: TimesheetEntry.where(id: entry.id), company: tenant_a.company)

    expect { gateway.call(command) }.to raise_error(gateway::OwnerUnavailable, /owner monolith .* BulkDiscard refused/)
    expect(entry.reload.discarded_at).to be_nil
  end

  it "refuses every command while a handoff away from it runs, with the retryable Moving (§10.1)" do
    set_timekeeping_ownership!(generation: 2, owner: "monolith", state: "closed")

    expect { gateway.call(create_command) }.to raise_error(Timekeeping::Ownership::Moving)
    expect(Timekeeping::Entry.count).to eq(0)
  end

  it "reaches the projection only through the local relay, on both tenants (§3.3, §6.3)" do
    entries = [written { create_command(tenant_a) }]
    act_as(tenant_b.employee, tenant_b)
    entries << written { create_command(tenant_b, note: "Kettle") }
    written { update_command(Timekeeping::Entry.find(entries.last.id), tenant_b, note: "Kettle, edited") }

    Timekeeping::LocalRelay.new.run

    aggregate_failures do
      entries.each do |created|
        entry = Timekeeping::Entry.find(created.id)
        expect(Timekeeping::StoredEntries.all.find { |row| row.fetch("id") == entry.id }).to eq(entry.to_contract)
      end
      expect(TimesheetEntry.find(entries.last.id)).to have_attributes(note: "Kettle, edited", version: 2)
      expect(TimesheetEntry.find(entries.first.id).project.client.company).to eq(tenant_a.company)
    end
  end
end
