# frozen_string_literal: true

require "rails_helper"

# The first cutover's checkpoint (docs/architecture/timekeeping-soa.md §10.5
# step 4), taken from the legacy owner while the handoff is frozen: every
# entry as a full snapshot and the reservation it becomes (§7.4). Each state
# is reached through the billing behaviour that produces it today (K1-K7), on
# two tenants, and the handoff is frozen only once it is built, as the fence
# refuses every write after it.
RSpec.describe Timekeeping::LegacyCheckpoint, type: :model do
  include_context "with two Timekeeping tenants"

  let(:entry) { unbilled_entry(tenant_a) }

  def freeze_handoff!(generation: 1, owner: "legacy")
    set_timekeeping_ownership!(generation:, owner:, state: "frozen")
  end

  def take(**options)
    freeze_handoff!
    described_class.take(generation: 1, **options)
  end

  def saved_draft(*entries)
    invoice_for(tenant_a).tap do |invoice|
      entries.each { |draft_entry| direct_line(invoice, draft_entry) }
      invoice.reload.save!
    end
  end

  def sent_after_draft(*entries)
    saved_draft(*entries).tap { |invoice| invoice.update!(status: :sent) }
  end

  def reservation_of(checkpoint, target)
    checkpoint.reservations.select { |reservation| reservation.entry_id == target.id }.sole
  end

  def entry_in(checkpoint, target)
    checkpoint.entries.find { |checkpointed| checkpointed.fetch("id") == target.id }
  end

  describe "where the handoff must be" do
    before { entry }

    {
      "admission still open" => { generation: 1, owner: "legacy", state: "open" },
      "admission closed, not frozen" => { generation: 1, owner: "legacy", state: "closed" },
      "frozen at another generation" => { generation: 2, owner: "legacy", state: "frozen" },
      "frozen while Timekeeping is the outgoing owner" => { generation: 1, owner: "timekeeping", state: "frozen" }
    }.each do |name, ownership|
      it "refuses with #{name}, and takes nothing" do
        set_timekeeping_ownership!(ownership)

        expect { described_class.take(generation: 1) }.to raise_error(described_class::OutOfStep, /nothing taken|nothing changed/)
      end
    end
  end

  describe "the reservation each entry becomes (§7.4)" do
    it "maps an entry on one kept draft to a committed, active reservation with its edit lock (L1)" do
      invoice = saved_draft(entry)

      checkpoint = take

      expect(reservation_of(checkpoint, entry)).to have_attributes(
        invoice_id: invoice.id, company_id: tenant_a.company.id, operation_id: nil,
        state: :committed, disposition: :active, edit_lock: true
      )
      expect(entry_in(checkpoint, entry)).to include("locked" => true)
    end

    it "maps an entry held by one discarded non-draft to a retained reservation that keeps its lock (L3)" do
      invoice = sent_after_draft(entry)
      invoice.discard!

      checkpoint = take

      expect(reservation_of(checkpoint, entry)).to have_attributes(
        invoice_id: invoice.id, state: :committed, disposition: :retained, edit_lock: true
      )
      expect(entry_in(checkpoint, entry)).to include("locked" => true)
    end

    it "releases an entry locked only by a discarded draft, so it reads unlocked (F2)" do
      saved_draft(entry).discard!
      expect(locked?(entry)).to be(true)

      checkpoint = take

      expect(checkpoint.reservations.map(&:entry_id)).not_to include(entry.id)
      expect(entry_in(checkpoint, entry)).to include("locked" => false)
    end

    it "gives an entry no invoice references no reservation" do
      entry
      checkpoint = take

      expect(checkpoint.reservations.map(&:entry_id)).not_to include(entry.id, bystander_entry.id)
      expect(entry_in(checkpoint, entry)).to include("locked" => false)
    end
  end

  describe "items the pre-flight lists (§10.4)" do
    it "refuses an unlocked link with no recorded disposition, and takes it once its invoice has one" do
      invoice = invoice_for(tenant_a, status: :sent)
      direct_line(invoice, entry)

      expect { take }.to raise_error(described_class::Undisposed) { |error|
        expect(error.lists).to eq(unlocked_links: [entry.id])
      }

      checkpoint = described_class.take(generation: 1, unlocked_link_invoice_ids: [invoice.id])

      expect(reservation_of(checkpoint, entry)).to have_attributes(
        invoice_id: invoice.id, state: :committed, disposition: :active, edit_lock: false
      )
      expect(entry_in(checkpoint, entry)).to include("locked" => false)
    end

    it "refuses an orphan: an entry left locked by a hard-destroyed non-draft (K7)" do
      sent_after_draft(entry).reload.destroy!

      expect { take }.to raise_error(described_class::Undisposed) { |error|
        expect(error.lists).to eq(orphans: [entry.id])
      }
    end

    it "refuses a conflict: an entry on two kept invoices (K6)" do
      saved_draft(entry)
      grouped_line(invoice_for(tenant_a), [entry])

      expect { take }.to raise_error(described_class::Undisposed, /conflicts #{entry.id}/) { |error|
        expect(error.lists).to eq(conflicts: [entry.id])
      }
    end
  end

  describe "the entries it carries" do
    it "carries every entry of both tenants, discarded ones included, as the contract's full entry" do
      discarded = unbilled_entry(tenant_a).tap(&:discard!)
      saved_draft(entry)

      checkpoint = take

      expect(checkpoint.entries.map { |checkpointed| checkpointed.fetch("id") }).to eq(TimesheetEntry.order(:id).ids)
      checkpoint.entries.each { |checkpointed| TimekeepingContracts.validate!(:common, "#/$defs/entry", checkpointed) }
      expect(entry_in(checkpoint, discarded)["discarded_at"]).to eq(discarded.reload.discarded_at.utc.iso8601(6))
      expect(entry_in(checkpoint, bystander_entry)).to include("company_id" => tenant_b.company.id, "locked" => false)
      expect(checkpoint.highest_entry_id).to eq(TimesheetEntry.maximum(:id))
    end

    it "copies every value as stored, at the first version Timekeeping holds" do
      entry.update_columns(duration: 90.7, created_at: Time.utc(2026, 11, 2, 9, 30, 15.123456r))

      checkpointed = entry_in(take, entry.reload)

      expect(checkpointed).to include(
        "duration" => 90.7, "version" => 1, "company_id" => tenant_a.company.id,
        "work_date" => entry.work_date.iso8601, "bill_status" => "unbilled",
        "created_at" => "2026-11-02T09:30:15.123456Z", "updated_at" => entry.updated_at.utc.iso8601(6)
      )
      expect(checkpointed.except("id", "company_id", "version", "locked").keys)
        .to match_array(TimesheetEntry.column_names - %w[id version locked])
    end

    it "writes nothing" do
      saved_draft(entry).discard!

      expect { take }.not_to change { TimesheetEntry.order(:id).pluck(:id, :locked, :version, :updated_at) }
    end
  end
end
