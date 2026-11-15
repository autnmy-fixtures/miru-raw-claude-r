# frozen_string_literal: true

require "rails_helper"

# The prepared application's relay (docs/architecture/timekeeping-soa.md
# §5.4, §10.1): what the `monolith` owner's entry changes record in its
# outbox reaches timesheet_entries through the projection consumer, its one
# writer, in outbox order, and a batch the projection does not take is never
# marked or skipped.
RSpec.describe Timekeeping::LocalRelay do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  subject(:relay) { described_class.new(clock: -> { delivered_at }) }

  let(:delivered_at) { Time.utc(2026, 11, 14, 12, 0, 0) }
  let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  def claims(tenant)
    Timekeeping::UserToken.caller_claims(
      user: tenant.employee, company: tenant.company, writer: "web", project: tenant.project, request_id: "req-#{SecureRandom.hex(4)}"
    )
  end

  # A prepared application's entry, created and recorded as a writer will
  # record it (Timekeeping::LocalEntryChange).
  def created!(tenant, offset: 0, company: tenant.company, user: tenant.employee, **attributes)
    Timekeeping::Entry.create!(
      id: first_id + offset, company_id: company.id, project_id: tenant.project.id, user_id: user.id,
      duration: 90.7, work_date: Date.new(2026, 11, 2), note: "Prep", bill_status: "unbilled",
      source: "cli", source_metadata: { "tool" => "miru-cli" }, **attributes
    ).tap { |entry| Timekeeping::LocalEntryChange.record!(entry, action: "create", audited_changes: { "note" => "Prep" }, claims: claims(tenant)) }
  end

  def updated!(entry, tenant, **attributes)
    entry.update!(**attributes, version: entry.version + 1)
    Timekeeping::LocalEntryChange.record!(entry, action: "update", audited_changes: {}, claims: claims(tenant))
    entry
  end

  def projected(entry)
    Timekeeping::StoredEntries.all.find { |row| row.fetch("id") == entry.id }
  end

  def undelivered_ids = Timekeeping::OutboxSnapshot.undelivered.pluck(:id)

  describe "delivery" do
    it "projects each recorded entry column for column, and marks its snapshot delivered" do
      entries = [created!(tenant_a), created!(tenant_b, offset: 1, duration: 479.99999)]

      expect(relay.run).to eq(described_class::Result.new(delivered: 2, undelivered: 0))
      aggregate_failures do
        entries.each { |entry| expect(projected(entry)).to eq(entry.reload.to_contract) }
        expect(TimesheetEntry.find(entries.last.id).duration).to eq(479.99999)
        expect(Timekeeping::OutboxSnapshot.pluck(:delivered_at)).to all(eq(delivered_at))
      end
    end

    it "projects the entry's derived `locked` (§3.2, §7.1)" do
      entry = created!(tenant_a)
      Timekeeping::Reservation.create!(
        entry_id: entry.id, invoice_id: 10, company_id: tenant_a.company.id, state: "committed", disposition: "active", edit_lock: true
      )
      updated!(entry, tenant_a)

      relay.run

      expect(TimesheetEntry.find(entry.id)).to have_attributes(locked: true, version: 2)
    end

    it "writes timesheet_entries only through the projection consumer's version upsert" do
      created!(tenant_a)
      allow(Timekeeping::ProjectionConsumer).to receive(:process).and_call_original

      writes = timesheet_entry_writes { relay.run }

      aggregate_failures do
        expect(Timekeeping::ProjectionConsumer).to have_received(:process).once
        expect(writes.map(&:sql)).to contain_exactly(a_string_matching(/\AINSERT INTO "timesheet_entries".*ON CONFLICT/m))
      end
    end

    it "applies the newest of several versions in the outbox, and marks every one" do
      entry = created!(tenant_a)
      updated!(entry, tenant_a, note: "Second")
      updated!(entry, tenant_a, note: "Third")

      expect(relay.run).to eq(described_class::Result.new(delivered: 3, undelivered: 0))
      expect(TimesheetEntry.find(entry.id)).to have_attributes(note: "Third", version: 3)
      expect(undelivered_ids).to eq([])
    end

    it "ignores a version older than the projection holds, so a repeat or a reorder is harmless" do
      entry = created!(tenant_a)
      updated!(entry, tenant_a, note: "Second")
      relay.run
      Timekeeping::OutboxSnapshot.update_all(delivered_at: nil)
      Timekeeping::OutboxSnapshot.where(version: 2).update_all(delivered_at: delivered_at)

      expect(relay.run).to eq(described_class::Result.new(delivered: 1, undelivered: 0))
      expect(TimesheetEntry.find(entry.id)).to have_attributes(note: "Second", version: 2)
    end

    it "delivers in batches, in outbox order, until the outbox is drained" do
      entries = Array.new(5) { |offset| created!(tenant_a, offset:) }
      batches = []
      allow(Timekeeping::ProjectionConsumer).to receive(:process).and_wrap_original do |original, snapshots|
        batches << snapshots.map { |snapshot| snapshot.fetch("entry_id") }
        original.call(snapshots)
      end

      expect(described_class.new(batch_size: 2).run).to eq(described_class::Result.new(delivered: 5, undelivered: 0))
      expect(batches).to eq(entries.map(&:id).each_slice(2).to_a)
    end

    it "delivers a lower position that was still undelivered when a higher one was delivered" do
      lower = created!(tenant_a)
      higher = created!(tenant_a, offset: 1)
      higher.outbox_snapshots.update_all(delivered_at: delivered_at)

      expect(relay.run).to eq(described_class::Result.new(delivered: 1, undelivered: 0))
      aggregate_failures do
        expect(TimesheetEntry.exists?(lower.id)).to be(true)
        expect(TimesheetEntry.exists?(higher.id)).to be(false)
      end
    end

    it "does nothing when the outbox has nothing to deliver" do
      created!(tenant_a)
      relay.run

      expect(Timekeeping::ProjectionConsumer).not_to receive(:process)
      expect(relay.run).to eq(described_class::Result.new(delivered: 0, undelivered: 0))
    end
  end

  describe "a batch the projection does not take" do
    before { allow(Rails.error).to receive(:report) }

    def expect_held(result, batch:)
      aggregate_failures do
        expect(result).to eq(described_class::Result.new(delivered: 0, undelivered: batch))
        expect(undelivered_ids).to eq(Timekeeping::OutboxSnapshot.order(:id).pluck(:id))
        expect(Rails.error).to have_received(:report).with(
          an_instance_of(described_class::Undelivered), hash_including(handled: true, context: hash_including(relay: "local_outbox"))
        )
      end
    end

    it "holds a batch naming another tenant's project, applying none of it (§6.3)" do
      good = created!(tenant_a)
      created!(tenant_a, offset: 1, company: tenant_b.company)

      expect_held(relay.run, batch: 2)
      expect(TimesheetEntry.exists?(good.id)).to be(false)
    end

    it "holds a batch the entry snapshot contract refuses" do
      good = created!(tenant_a)
      broken = created!(tenant_a, offset: 1)
      broken.outbox_snapshots.update_all(snapshot: { "type" => "timekeeping.entry_snapshot.v1", "entry_id" => broken.id })

      expect_held(relay.run, batch: 2)
      expect(TimesheetEntry.exists?(good.id)).to be(false)
    end

    it "holds a batch the database refuses, such as an entry of a user who no longer exists" do
      good = created!(tenant_a)
      created!(tenant_a, offset: 1, user: User.new(id: User.maximum(:id).to_i + 1_000))

      expect_held(relay.run, batch: 2)
      expect(TimesheetEntry.exists?(good.id)).to be(false)
    end

    it "keeps holding it at the head of the outbox, so nothing behind it is skipped" do
      created!(tenant_a, company: tenant_b.company)
      behind = created!(tenant_a, offset: 1)
      relay = described_class.new(batch_size: 1)

      2.times { expect(relay.run).to eq(described_class::Result.new(delivered: 0, undelivered: 1)) }
      aggregate_failures do
        expect(undelivered_ids.size).to eq(2)
        expect(TimesheetEntry.exists?(behind.id)).to be(false)
      end
    end
  end

  describe "across connections" do
    include TimekeepingConnections

    # Rows committed from a connection of their own, deleted afterwards. The
    # projection never sees them: the relay under test takes none.
    let(:ids) { [first_id, first_id + 1] }

    before do
      run_on_own_connection do
        ids.each do |id|
          entry = Timekeeping::Entry.create!(
            id:, company_id: 1, project_id: 1, user_id: 1, duration: 30.0, work_date: Date.new(2026, 11, 2), bill_status: "unbilled"
          )
          entry.outbox_snapshots.create!(company_id: 1, version: 1, snapshot: Timekeeping::OutboxSnapshot.of(entry), request_id: "req")
        end
      end
    end

    after do
      run_on_own_connection do
        Timekeeping::OutboxSnapshot.where(entry_id: ids).delete_all
        Timekeeping::Entry.where(id: ids).delete_all
      end
    end

    it "skips the rows another relay holds, instead of waiting for them or delivering them twice" do
      held = Queue.new
      finish = Queue.new
      other_relay = on_own_connection do
        Timekeeping::OutboxSnapshot.transaction do
          Timekeeping::OutboxSnapshot.undelivered.lock("FOR UPDATE SKIP LOCKED").to_a
          held << true
          finish.pop(timeout: wait_seconds)
        end
      end

      begin
        take(held)
        result = run_on_own_connection { described_class.new.run }
        expect(result).to eq(described_class::Result.new(delivered: 0, undelivered: 0))
      ensure
        finish << true
        other_relay.join
      end
    end
  end
end
