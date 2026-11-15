# frozen_string_literal: true

require "rails_helper"

# The prepared application's entry tables (docs/architecture/timekeeping-soa.md
# §3.2, §10.5): the authoritative entries the `monolith` owner holds after a
# rollback, their audit rows and the entry API's idempotency receipts. They
# are Timekeeping's tables, column for column, so a checkpoint carries an
# entry between the two owners unchanged.
RSpec.describe "Timekeeping local entry tables", type: :model do
  # A full entry as the contracts carry it (common.json#/$defs/entry), with
  # the values that are easiest to lose on the way: a float duration,
  # microsecond timestamps and metadata.
  def contract_entry(**fields)
    {
      "id" => 101, "company_id" => 42, "version" => 3,
      "project_id" => 7, "user_id" => 9, "agent_id" => 5,
      "duration" => 90.7, "work_date" => "2026-11-02", "note" => "Pairing on the relay",
      "bill_status" => "unbilled", "review_status" => "pending_review", "locked" => false,
      "source" => "cli", "source_metadata" => { "tool" => "miru-cli" },
      "proof_url" => "https://example.test/run/1", "proof_metadata" => { "commit" => "abc123" },
      "external_run_id" => "run-1", "external_session_id" => "session-1",
      "discarded_at" => nil, "created_at" => "2026-11-02T09:30:15.123456Z", "updated_at" => "2026-11-02T09:31:00.000001Z"
    }.merge(fields.transform_keys(&:to_s))
  end

  def entry!(**fields)
    Timekeeping::Entry.create!(Timekeeping::Entry.row_for(contract_entry(**fields)))
  end

  def reservation!(entry, invoice_id:, edit_lock:, disposition: "active")
    Timekeeping::Reservation.create!(
      entry_id: entry.id, invoice_id:, company_id: entry.company_id, operation_id: nil, state: "committed", disposition:, edit_lock:
    )
  end

  def refused(&)
    expect { ActiveRecord::Base.transaction(requires_new: true, &) }
  end

  describe Timekeeping::Entry do
    it "round-trips a contract entry column for column, under the id it carries" do
      carried = contract_entry
      TimekeepingContracts.validate!(:common, "#/$defs/entry", carried)

      entry = entry!

      aggregate_failures do
        expect(entry.id).to eq(101)
        expect(Timekeeping::Entry.find(101).to_contract).to eq(carried)
        expect(entry.reload.duration).to eq(90.7)
        expect(entry.created_at.nsec).to eq(123_456_000)
      end
    end

    it "carries a discarded entry, and keeps it out of `kept`" do
      entry = entry!(discarded_at: "2026-11-03T08:00:00.000002Z")

      aggregate_failures do
        expect(entry.reload.to_contract).to include("discarded_at" => "2026-11-03T08:00:00.000002Z")
        expect(Timekeeping::Entry.kept).not_to include(entry)
      end
    end

    it "derives `locked` from its reservations by the shared rule, never from a column (§7.1)" do
      entry = entry!

      aggregate_failures do
        expect(Timekeeping::Entry.column_names).not_to include("locked")
        expect(entry.to_contract).to include("locked" => false)

        reservation!(entry, invoice_id: 10, edit_lock: false)
        expect(entry.reload.to_contract).to include("locked" => false)

        reservation!(entry, invoice_id: 11, edit_lock: true, disposition: "retained")
        expect(entry.reload.to_contract).to include("locked" => true)
      end
    end

    it "scopes by tenant (§6.3)" do
      ours = entry!
      entry!(id: 102, company_id: 43)

      expect(Timekeeping::Entry.of_company(42)).to contain_exactly(ours)
    end

    it "stores only the enum names the contracts carry, and versions from 1" do
      aggregate_failures do
        refused { entry!(bill_status: "pending") }.to raise_error(ActiveRecord::StatementInvalid, /timekeeping_entries_bill_status/)
        refused { entry!(review_status: "waiting") }.to raise_error(ActiveRecord::StatementInvalid, /timekeeping_entries_review_status/)
        refused { entry!(source: "email") }.to raise_error(ActiveRecord::StatementInvalid, /timekeeping_entries_source/)
        refused { entry!(version: 0) }.to raise_error(ActiveRecord::StatementInvalid, /timekeeping_entries_version_positive/)
      end
    end

    it "keeps an entry that has audit rows or reservations" do
      entry = entry!
      reservation!(entry, invoice_id: 10, edit_lock: true)

      expect { entry.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
    end
  end

  describe Timekeeping::EntryAudit do
    def audit!(entry_id, action: "update")
      Timekeeping::EntryAudit.create!(
        entry_id:, company_id: 42, action:, audited_changes: { "note" => ["", "Pairing"] }, version: 2,
        actor: "user:9", agent_id: nil, writer: "web", request_id: SecureRandom.uuid
      )
    end

    it "records a change of an entry it belongs to" do
      entry = entry!
      audit = audit!(entry.id)

      expect(entry.audits).to contain_exactly(audit)
      expect(audit.reload).to have_attributes(action_update?: true, audited_changes: { "note" => ["", "Pairing"] })
    end

    # Written around the model, as a caller that skipped its enum and
    # belongs_to would: the table is the backstop.
    def raw_audit!(entry_id, action: "update")
      Timekeeping::EntryAudit.connection.exec_insert(<<~SQL.squish, "raw audit", [entry_id, action])
        INSERT INTO timekeeping_entry_audits
          (entry_id, company_id, action, audited_changes, version, actor, writer, request_id, created_at)
        VALUES ($1, 42, $2, '{}', 2, 'system', 'web', 'request-1', now())
      SQL
    end

    it "takes only audited's action names, and only for an entry that exists" do
      entry = entry!

      aggregate_failures do
        expect { raw_audit!(entry.id) }.not_to raise_error
        refused { raw_audit!(entry.id, action: "destroy") }.to raise_error(ActiveRecord::StatementInvalid, /timekeeping_entry_audits_action/)
        refused { raw_audit!(entry.id + 1) }.to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end
  end

  describe Timekeeping::OutboxSnapshot do
    def outbox!(entry_id, version: 3)
      Timekeeping::OutboxSnapshot.create!(entry_id:, company_id: 42, version:, snapshot: { "entry_id" => entry_id }, request_id: "request-1")
    end

    it "renders an entry as the contract's entry snapshot, with its tenant and version lifted out of `data` (§5.4)" do
      entry = entry!
      snapshot = Timekeeping::OutboxSnapshot.of(entry)

      aggregate_failures do
        expect { TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", snapshot) }.not_to raise_error
        expect(snapshot).to eq(
          "type" => "timekeeping.entry_snapshot.v1", "entry_id" => 101, "version" => 3, "company_id" => 42,
          "data" => contract_entry.except("id", "company_id", "version")
        )
      end
    end

    it "holds one snapshot per entry version, only for an entry that exists, and keeps the entry it belongs to" do
      entry = entry!
      outbox!(entry.id)

      aggregate_failures do
        refused { outbox!(entry.id) }.to raise_error(ActiveRecord::RecordNotUnique)
        expect { outbox!(entry.id, version: 4) }.not_to raise_error
        refused {
          Timekeeping::OutboxSnapshot.insert!(
            { entry_id: entry.id + 1, company_id: 42, version: 3, snapshot: {}, request_id: "request-1", created_at: Time.current }
          )
        }.to raise_error(ActiveRecord::InvalidForeignKey)
        expect { entry.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
      end
    end

    it "queues only what is undelivered, in outbox order" do
      entry = entry!
      first, second, third = [3, 4, 5].map { |version| outbox!(entry.id, version:) }
      second.update!(delivered_at: Time.current)

      expect(Timekeeping::OutboxSnapshot.undelivered).to eq([first, third])
    end
  end

  describe Timekeeping::IdempotencyReceipt do
    def receipt!(company_id: 42, key: "key-1", request_digest: "digest-1")
      Timekeeping::IdempotencyReceipt.create!(company_id:, key:, request_digest:, status: 201, response: { "entry" => { "id" => 101 } })
    end

    it "replays its answer for the request it answered, and nothing for another" do
      receipt = receipt!.reload

      aggregate_failures do
        expect(receipt.replay("digest-1")).to eq([201, { "entry" => { "id" => 101 } }])
        expect(receipt.replay("digest-2")).to be_nil
      end
    end

    it "holds one receipt per key in a tenant, and lets another tenant use the same key (§6.3)" do
      receipt!

      aggregate_failures do
        refused { receipt!(request_digest: "digest-2") }.to raise_error(ActiveRecord::RecordNotUnique)
        expect { receipt!(company_id: 43) }.not_to raise_error
      end
    end
  end
end
