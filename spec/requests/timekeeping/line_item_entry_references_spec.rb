# frozen_string_literal: true

require "rails_helper"

# Billing's references to entries once the two foreign keys are gone
# (docs/architecture/timekeeping-soa.md §10.2 step 3). The keys were the only
# thing that refused a line item naming an entry that does not exist. The
# models now say so themselves, so a client still cannot invoice an entry id
# that is not there, and nothing is saved.
RSpec.describe "Timekeeping: line item entry references", type: :request do
  include_context "with two Timekeeping tenants"

  let(:admin) { tenant_a.admin }
  let(:entry) { unbilled_entry(tenant_a) }
  let(:missing_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

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

  def line(**attributes)
    { name: "Work", date: Date.current.iso8601, quantity: 60, rate: 100, **attributes }
  end

  def billing_rows
    [Invoice.count, InvoiceLineItem.count, InvoiceLineItemTimeEntry.count]
  end

  it "refuses a direct line naming a missing entry with 422 and saves nothing" do
    expect { create_invoice([line(timesheet_entry_id: missing_id)]) }.not_to change { billing_rows }

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response["errors"]).to eq("Invoice line items timesheet entry must exist")
  end

  it "refuses an edit that points a saved line at a missing entry" do
    create_invoice([line(timesheet_entry_id: entry.id)])
    invoice = Invoice.find(json_response["id"])
    line_item = invoice.invoice_line_items.sole

    send_request :patch, api_v1_invoice_path(invoice), params: {
      invoice: { invoice_line_items_attributes: [{ id: line_item.id, timesheet_entry_id: missing_id }] }
    }, headers: auth_headers(admin)

    expect(response).to have_http_status(:unprocessable_content)
    expect(line_item.reload.timesheet_entry_id).to eq(entry.id)
  end

  it "still answers 404 for a grouped line linking a missing entry, as before the keys were dropped" do
    expect {
      create_invoice([line(linked_timesheet_entry_ids: [entry.id, missing_id])])
    }.not_to change { billing_rows }

    expect(response).to have_http_status(:not_found)
  end

  it "still invoices an existing entry directly and through a grouped line" do
    other = unbilled_entry(tenant_a)

    create_invoice([line(timesheet_entry_id: entry.id), line(linked_timesheet_entry_ids: [other.id])])

    expect(response).to have_http_status(:ok)
    invoice = Invoice.find(json_response["id"])
    expect(invoice.invoice_line_items.pluck(:timesheet_entry_id)).to contain_exactly(entry.id, nil)
    expect(invoice.invoice_line_items.flat_map(&:linked_timesheet_entry_ids)).to eq([other.id])
    expect(locked?(entry)).to be(true)
    expect(locked?(other)).to be(true)
  end
end
