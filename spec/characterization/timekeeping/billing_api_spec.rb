# frozen_string_literal: true

require "rails_helper"

# Characterization: pins billing writes made through the API
# (docs/architecture/timekeeping-soa.md §1.4, §1.5, §2.3, Appendix A K6,
# K7, K9). F1 flips the double-allocation case in the change that ships it.
RSpec.describe "Timekeeping characterization: billing API", type: :request do
  include_context "with two Timekeeping tenants"

  let(:admin) { tenant_a.admin }
  let(:entry) { unbilled_entry(tenant_a) }

  before { sign_in admin }

  def create_invoice(line_items)
    send_request :post, api_v1_invoices_path, params: {
      invoice: {
        client_id: tenant_a.client.id,
        invoice_number: "TK-#{SecureRandom.hex(3)}",
        issue_date: Date.current.iso8601,
        due_date: Date.current.iso8601,
        status: "draft",
        currency: tenant_a.company.base_currency,
        invoice_line_items_attributes: line_items
      }
    }, headers: auth_headers(admin)
  end

  def line_for(entry, quantity: entry.duration, rate: 100)
    { name: "Work", date: entry.work_date.iso8601, timesheet_entry_id: entry.id, quantity:, rate: }
  end

  describe "M3 / K9: line quantity" do
    it "casts a fractional posted quantity to whole minutes and totals on the cast value" do
      create_invoice([line_for(entry, quantity: 90.7)])

      expect(response).to have_http_status(:ok)
      invoice = Invoice.find(json_response["id"])
      expect(invoice.invoice_line_items.sole.quantity).to eq(90)
      expect(invoice.amount.to_f).to eq(150.0)
    end
  end

  describe "F1 / K6: double allocation through explicit ids (flipped by F1)" do
    it "accepts a second kept invoice for an entry already on a kept invoice and locks the one boolean" do
      create_invoice([line_for(entry)])
      first_id = json_response["id"]

      create_invoice([line_for(entry)])

      expect(response).to have_http_status(:ok)
      expect(InvoiceLineItem.where(timesheet_entry_id: entry.id).pluck(:invoice_id))
        .to contain_exactly(first_id, json_response["id"])
      expect(entry.reload.locked).to be(true)
    end
  end

  describe "K7: bulk delete is hard, single delete is soft" do
    def lock_on(status)
      invoice = invoice_for(tenant_a)
      direct_line(invoice, entry)
      invoice.reload.save!
      invoice.update!(status:)
      invoice
    end

    def bulk_delete(*invoices)
      send_request :post, api_v1_invoices_bulk_deletion_index_path,
        params: { invoices_ids: invoices.map(&:id) }, headers: auth_headers(admin)
    end

    it "soft-deletes on single delete and keeps the draft's entry locked (L2)" do
      invoice = lock_on(:draft)

      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)

      expect(invoice.reload.discarded_at).to be_present
      expect(entry.reload.locked).to be(true)
    end

    it "hard-deletes a sent invoice and leaves its entry locked with no row referencing it" do
      invoice = lock_on(:sent)

      bulk_delete(invoice)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect(entry.reload.locked).to be(true)
      expect(InvoiceLineItem.where(timesheet_entry_id: entry.id)).to be_empty
    end

    it "hard-deletes an already-discarded draft, with no kept filter, and releases its entry" do
      invoice = lock_on(:draft)
      invoice.discard!
      expect(entry.reload.locked).to be(true)

      bulk_delete(invoice)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect(entry.reload.locked).to be(false)
    end
  end
end
