# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §3.2, §5.4 and §6.3: the projection
# consumer upserts snapshots by (entry_id, version), copies values as they
# arrive, and never projects one tenant's entry into another's.
RSpec.describe Timekeeping::ProjectionConsumer, type: :model do
  include TimekeepingCharacterization::Helpers

  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:new_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  def snapshot_for(tenant, entry_id:, version:, user: tenant.employee, **data)
    relay.snapshot(
      entry_id:, version:, company_id: tenant.company.id, project_id: tenant.project.id, user_id: user.id,
      duration: 90.7, work_date: "2026-11-02", **data
    )
  end

  def apply(*snapshots)
    described_class.process(snapshots)
  end

  describe "a new entry" do
    it "inserts the row with every column as the snapshot carries it" do
      created_at = "2026-11-02T09:15:30.123456Z"
      snapshot = snapshot_for(
        tenant_a, entry_id: new_id, version: 3, duration: 479.99999, note: "Prep", bill_status: "billed",
        review_status: "pending_review", locked: true, source: "automation", source_metadata: { "mcp_server" => "x" },
        proof_metadata: { "kind" => "photo" }, external_run_id: "run-1", created_at:, updated_at: created_at
      )

      expect(apply(snapshot)).to eq(described_class::Applied.new(applied: 1, ignored: 0))
      row = TimesheetEntry.find(new_id)
      expect(row).to have_attributes(
        version: 3, project_id: tenant_a.project.id, user_id: tenant_a.employee.id, duration: 479.99999,
        work_date: Date.new(2026, 11, 2), note: "Prep", bill_status: "billed", review_status: "pending_review",
        locked: true, source_metadata: { "mcp_server" => "x" }, proof_metadata: { "kind" => "photo" },
        external_run_id: "run-1", discarded_at: nil, created_at: Time.iso8601(created_at), updated_at: Time.iso8601(created_at)
      )
    end

    # A model save would rewrite source to "mcp" (A10, K10) and audit the
    # change. The projection is a copy of what Timekeeping already decided.
    it "runs no model rule, callback or audit" do
      snapshot = snapshot_for(tenant_a, entry_id: new_id, version: 1, source: "automation", source_metadata: { "mcp_server" => "x" })

      expect { apply(snapshot) }.not_to change(Audited::Audit, :count)
      expect(TimesheetEntry.find(new_id).source).to eq("automation")
    end

    it "reads a timestamp with an offset as the instant it names" do
      apply(snapshot_for(tenant_a, entry_id: new_id, version: 1, created_at: "2026-11-02T14:45:00+05:30"))

      expect(TimesheetEntry.find(new_id).created_at).to eq(Time.utc(2026, 11, 2, 9, 15))
    end
  end

  describe "an existing row" do
    let(:entry) { unbilled_entry(tenant_a, duration: 60.0) }

    it "starts at version 0, so the first snapshot overwrites what was written before Timekeeping owned it" do
      expect(entry.version).to eq(0)

      expect(apply(snapshot_for(tenant_a, entry_id: entry.id, version: 1, duration: 61.5, locked: true)).applied).to eq(1)
      expect(entry.reload).to have_attributes(version: 1, duration: 61.5, locked: true)
    end

    it "applies only a higher version" do
      apply(snapshot_for(tenant_a, entry_id: entry.id, version: 5, duration: 75.0))

      expect(apply(snapshot_for(tenant_a, entry_id: entry.id, version: 5, duration: 1.0))).to eq(described_class::Applied.new(applied: 0, ignored: 1))
      expect(apply(snapshot_for(tenant_a, entry_id: entry.id, version: 4, duration: 2.0))).to eq(described_class::Applied.new(applied: 0, ignored: 1))
      expect(entry.reload).to have_attributes(version: 5, duration: 75.0)
      expect(apply(snapshot_for(tenant_a, entry_id: entry.id, version: 6, duration: 3.0)).applied).to eq(1)
      expect(entry.reload).to have_attributes(version: 6, duration: 3.0)
    end

    it "projects a discard and the derived lock" do
      discarded_at = "2026-11-03T10:00:00Z"
      apply(snapshot_for(tenant_a, entry_id: entry.id, version: 1, locked: true, discarded_at:))

      expect(TimesheetEntry.with_discarded.find(entry.id)).to have_attributes(locked: true, discarded_at: Time.iso8601(discarded_at))
    end
  end

  describe "a batch" do
    let(:entry) { unbilled_entry(tenant_a) }

    it "keeps the highest version of each entry whatever the order, and counts the rest as ignored" do
      v1, v2, v3 = (1..3).map { |version| snapshot_for(tenant_a, entry_id: entry.id, version:, duration: version * 10.0) }

      expect(apply(v1, v3, v2, v3, v1)).to eq(described_class::Applied.new(applied: 1, ignored: 4))
      expect(entry.reload).to have_attributes(version: 3, duration: 30.0)
    end

    it "applies the entries of both tenants together" do
      other = unbilled_entry(tenant_b)

      expect(apply(snapshot_for(tenant_a, entry_id: entry.id, version: 1), snapshot_for(tenant_b, entry_id: other.id, version: 1)).applied).to eq(2)
      expect([entry.reload.version, other.reload.version]).to eq([1, 1])
    end
  end

  # §6.3: a snapshot is projected only into its own company.
  describe "tenant isolation" do
    let!(:entry_a) { unbilled_entry(tenant_a, duration: 60.0) }
    let!(:entry_b) { unbilled_entry(tenant_b, duration: 60.0) }

    def refused(*snapshots)
      outcome = nil
      expect { outcome = apply(*snapshots) }.not_to change { TimesheetEntry.order(:id).pluck(:id, :version, :project_id, :duration) }
      outcome
    end

    it "refuses a snapshot whose project belongs to another company" do
      foreign = snapshot_for(tenant_a, entry_id: new_id, version: 1).merge("company_id" => tenant_b.company.id)

      expect(refused(foreign)).to eq(described_class::Refused.new(entry_ids: [new_id]))
    end

    it "refuses to overwrite another company's row, even through that company's own project" do
      takeover = snapshot_for(tenant_a, entry_id: entry_b.id, version: 1)

      expect(refused(takeover)).to eq(described_class::Refused.new(entry_ids: [entry_b.id]))
      expect(entry_b.reload.project_id).to eq(tenant_b.project.id)
    end

    it "refuses a project it does not know" do
      unknown = snapshot_for(tenant_a, entry_id: new_id, version: 1)
      unknown["data"]["project_id"] = Project.maximum(:id) + 1

      expect(refused(unknown)).to eq(described_class::Refused.new(entry_ids: [new_id]))
    end

    it "applies nothing of a batch that holds one foreign snapshot" do
      own = snapshot_for(tenant_a, entry_id: entry_a.id, version: 1, duration: 5.0)
      takeover = snapshot_for(tenant_a, entry_id: entry_b.id, version: 1)

      expect(refused(own, takeover)).to eq(described_class::Refused.new(entry_ids: [entry_b.id]))
      expect(entry_a.reload.duration).to eq(60.0)
    end
  end
end
