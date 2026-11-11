# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §7.4 and §10.4. Each state is reached
# through the billing behaviour that produces it today (K1-K7), on two tenants.
RSpec.describe Timekeeping::Preflight, type: :model do
  include_context "with two Timekeeping tenants"

  let(:entry) { unbilled_entry(tenant_a) }

  def classified(target)
    described_class.process.entries.find { |classified_entry| classified_entry.entry_id == target.id }
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

  describe ".mapping_for" do
    def mapping(kept:, locked:, non_drafts: :none, drafts: :none)
      described_class.mapping_for(
        described_class::Facts.new(kept:, locked:, discarded_non_drafts: non_drafts, discarded_drafts: drafts)
      )
    end

    it "maps each row of the §7.4 table" do
      expect(
        [
          mapping(kept: :many, locked: true),
          mapping(kept: :one, locked: false, non_drafts: :many),
          mapping(kept: :none, locked: false, drafts: :one),
          mapping(kept: :none, locked: true),
          mapping(kept: :none, locked: true, non_drafts: :one),
          mapping(kept: :none, locked: true, drafts: :many),
          mapping(kept: :none, locked: true, non_drafts: :one, drafts: :one),
          mapping(kept: :none, locked: true, non_drafts: :many)
        ]
      ).to eq(%i[conflict active none orphan retained released conflict conflict])
    end
  end

  describe ".process" do
    it "maps an entry on one kept draft to an active reservation that holds its lock" do
      invoice = saved_draft(entry)

      expect(classified(entry)).to have_attributes(
        mapping: :active, locked: true, unlocked_link?: false, kept_invoice_ids: [invoice.id],
        company_id: tenant_a.company.id
      )
    end

    it "counts an invoice once when a direct and a grouped line both reference the entry" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      grouped_line(invoice, [entry])

      expect(classified(entry)).to have_attributes(mapping: :active, kept_invoice_ids: [invoice.id])
    end

    it "lists an entry on a kept invoice that no draft save locked as an unlocked link (L1)" do
      invoice = invoice_for(tenant_a, status: :sent)
      direct_line(invoice, entry)

      report = described_class.process

      expect(report.unlocked_links.map(&:entry_id)).to eq([entry.id])
      expect(report.unlocked_links.first.kept_invoice_ids).to eq([invoice.id])
    end

    it "lists an entry on two kept invoices as a conflict (K6)" do
      first = saved_draft(entry)
      second = invoice_for(tenant_a)
      grouped_line(second, [entry])

      report = described_class.process

      expect(report.conflicts.map(&:entry_id)).to eq([entry.id])
      expect(report.conflicts.first.kept_invoice_ids).to contain_exactly(first.id, second.id)
    end

    it "lists a grouped line's entry left locked on a draft as an orphan (L4 quirk)" do
      linked = unbilled_entry(tenant_a)
      invoice = invoice_for(tenant_a)
      line = grouped_line(invoice, [linked])
      invoice.reload.save!
      line.reload.destroy!

      expect(described_class.process.orphans.map(&:entry_id)).to eq([linked.id])
    end

    it "lists an entry left locked by a hard-destroyed non-draft as an orphan (K7)" do
      sent_after_draft(entry).reload.destroy!

      expect(described_class.process.orphans.map(&:entry_id)).to eq([entry.id])
    end

    it "lists an entry held by one discarded non-draft as retained (L3)" do
      invoice = sent_after_draft(entry)
      invoice.discard!

      report = described_class.process

      expect(report.retained.map(&:entry_id)).to eq([entry.id])
      expect(report.retained.first.discarded_invoice_ids).to eq([invoice.id])
    end

    it "lists an entry locked only by a discarded draft as released (F2)" do
      saved_draft(entry).discard!

      expect(described_class.process.released.map(&:entry_id)).to eq([entry.id])
    end

    it "lists a locked entry held by two discarded non-drafts as a conflict" do
      sent_after_draft(entry).discard!
      sent_after_draft(entry).discard!

      expect(described_class.process.conflicts.map(&:entry_id)).to eq([entry.id])
    end

    it "maps an unlocked entry referenced only by a discarded invoice to no reservation" do
      invoice = invoice_for(tenant_a, status: :sent)
      direct_line(invoice, entry)
      invoice.discard!

      expect(classified(entry).mapping).to eq(:none)
    end

    it "classifies each tenant's entries under its own company and writes nothing" do
      saved_draft(entry)

      expect { described_class.process }.not_to change { TimesheetEntry.order(:id).pluck(:id, :locked, :updated_at) }
      expect(classified(bystander_entry)).to have_attributes(mapping: :none, company_id: tenant_b.company.id)
    end
  end
end
