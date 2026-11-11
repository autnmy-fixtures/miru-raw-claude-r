# frozen_string_literal: true

require "rails_helper"

# Characterization: pins how billing writes timesheet_entries.locked today
# (docs/architecture/timekeeping-soa.md §1.4, §2.3, Appendix A K1-K7).
# These specs describe current behaviour, quirks included. F1, F2 and F3
# (§2.3) flip the cases marked below in the change that ships each fix.
RSpec.describe "Timekeeping characterization: invoice locking", type: :model do
  include_context "with two Timekeeping tenants"

  let(:entry) { unbilled_entry(tenant_a) }

  def candidate_ids(tenant)
    GenerateInvoice::NewLineItemsService.new(tenant.client, {}).process[:new_line_item_entries]
      .pluck(:timesheet_entry_id)
  end

  describe "L1 / K1: saving a draft" do
    it "locks every entry the draft references, direct and linked, and leaves bill_status unbilled" do
      linked = unbilled_entry(tenant_a)
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      grouped_line(invoice, [linked])

      invoice.reload.save!

      expect([locked?(entry), locked?(linked)]).to eq([true, true])
      expect([entry.bill_status, linked.bill_status]).to eq(%w[unbilled unbilled])
    end

    it "does not lock entries added while the invoice is not a draft" do
      invoice = invoice_for(tenant_a, status: :sent)
      direct_line(invoice, entry)

      invoice.reload.save!

      expect(locked?(entry)).to be(false)
    end
  end

  describe "L2 / K2: discarding a draft (flipped by F2)" do
    it "leaves its entries locked, because update_invoice_number re-fires the draft lock" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!

      invoice.discard!

      expect(locked?(entry)).to be(true)
      expect(invoice.reload.invoice_number).to start_with("#{Invoice::ARCHIVED_PREFIX}-#{invoice.id}-")
    end
  end

  describe "L3 / K3: discarding a non-draft" do
    it "keeps its entries locked and makes them selectable for a new invoice again" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!
      invoice.update!(status: :sent)
      expect(candidate_ids(tenant_a)).not_to include(entry.id)

      invoice.discard!

      expect(locked?(entry)).to be(true)
      expect(candidate_ids(tenant_a)).to include(entry.id)
    end
  end

  describe "L4 / K4: removing a line item" do
    it "releases the direct entry on a draft" do
      invoice = invoice_for(tenant_a)
      line = direct_line(invoice, entry)
      invoice.reload.save!

      line.reload.destroy!

      expect(locked?(entry)).to be(false)
    end

    it "keeps the direct entry locked on a sent invoice" do
      invoice = invoice_for(tenant_a)
      line = direct_line(invoice, entry)
      invoice.reload.save!
      invoice.update!(status: :sent)

      line.reload.destroy!

      expect(locked?(entry)).to be(true)
    end

    it "leaves a grouped line's linked entries locked on a draft, with no invoice referencing them (flipped by F3)" do
      linked = [unbilled_entry(tenant_a), unbilled_entry(tenant_a)]
      invoice = invoice_for(tenant_a)
      line = grouped_line(invoice, linked)
      invoice.reload.save!

      line.reload.destroy!

      expect(linked.map { |linked_entry| locked?(linked_entry) }).to eq([true, true])
      expect(InvoiceLineItemTimeEntry.where(timesheet_entry_id: linked.map(&:id))).to be_empty
    end
  end

  describe "L6 / K5: sending" do
    it "moves the invoice to sent and leaves its entries unbilled and locked" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!

      invoice.record_send!(recipients_count: 1)

      expect(invoice.reload.status).to eq("sent")
      expect(entry.reload.bill_status).to eq("unbilled")
      expect(entry.locked).to be(true)
    end
  end

  describe "F1 / K6: double allocation (flipped by F1)" do
    it "lets one entry sit on two kept invoices" do
      first = invoice_for(tenant_a)
      second = invoice_for(tenant_a)

      direct_line(first, entry)
      direct_line(second, entry)

      expect(InvoiceLineItem.where(timesheet_entry_id: entry.id).pluck(:invoice_id)).to contain_exactly(first.id, second.id)
    end

    it "hides an entry already on a kept invoice from candidate selection" do
      direct_line(invoice_for(tenant_a), entry)

      expect(candidate_ids(tenant_a)).not_to include(entry.id)
    end
  end

  describe "K7: hard destroy" do
    it "releases the entries of a draft" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!

      invoice.destroy!

      expect(locked?(entry)).to be(false)
    end

    it "removes a sent invoice's line items and leaves its entries locked, referenced by no row" do
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!
      invoice.update!(status: :sent)

      invoice.destroy!

      expect(locked?(entry)).to be(true)
      expect(InvoiceLineItem.where(timesheet_entry_id: entry.id)).to be_empty
    end
  end

  describe "L8: tenant boundary" do
    it "refuses a line item that references another company's entry" do
      invoice = invoice_for(tenant_a)
      line = build(:invoice_line_item, invoice:, timesheet_entry: bystander_entry)

      expect(line).not_to be_valid
      expect(line.errors[:timesheet_entry]).to include("must belong to the same company")
    end
  end
end
