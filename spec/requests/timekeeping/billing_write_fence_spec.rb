# frozen_string_literal: true

require "rails_helper"

# The billing-write fence of docs/architecture/timekeeping-soa.md §10.1,
# through the real entry points: while a handoff has admission closed, every
# invoice, line-item, invoice-tax and payment write is refused with a
# retryable 503 ownership-moving, and no billing row changes. Mobile
# collections are included: they create invoices and payments outside
# InvoicePolicy (§1.4) and never touch an entry, so only this fence stops
# them. The model spec covers every billing model in every ownership state.
RSpec.describe "Timekeeping billing-write fence: billing writes are refused while admission is closed", type: :request do
  include_context "with two Timekeeping tenants"

  let(:moving) { I18n.t("timesheet_entry.ownership_moving") }
  let!(:sent_invoice) { invoice_for(tenant_a, status: :sent).tap { |invoice| invoice.update!(amount: 100, amount_due: 100) } }

  def close_admission!
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed"))
  end

  def billing_rows
    [Invoice, InvoiceLineItem, InvoiceLineItemTimeEntry, InvoiceTax, Payment, Client].to_h do |model|
      [model.name, model.order(:id).map(&:attributes)]
    end
  end

  def expect_refused_without_billing_writes
    before = billing_rows
    yield
    expect(response).to have_http_status(:service_unavailable)
    expect(json_response["errors"]).to eq(moving)
    expect(billing_rows).to eq(before)
  end

  def invoice_attributes(invoice, **attributes)
    {
      client_id: invoice.client_id,
      invoice_number: invoice.invoice_number,
      issue_date: invoice.issue_date.iso8601,
      due_date: invoice.due_date.iso8601,
      currency: invoice.currency,
      **attributes
    }
  end

  describe "invoices, line items and invoice taxes" do
    before { sign_in tenant_a.admin }

    it "refuses an invoice create with its line items and taxes" do
      close_admission!

      expect_refused_without_billing_writes do
        send_request :post, api_v1_invoices_path, params: {
          invoice: {
            client_id: tenant_a.client.id, invoice_number: "FENCE-1", status: "sent",
            issue_date: Date.current.iso8601, due_date: Date.current.iso8601,
            invoice_line_items_attributes: [{ name: "Fenced", date: Date.current.iso8601, rate: 100, quantity: 60 }],
            invoice_taxes_attributes: [{ name: "GST", calculation_method: "percentage", value: 10 }]
          }
        }, headers: auth_headers(tenant_a.admin)
      end
    end

    it "refuses an update of a sent invoice, which never reaches an entry" do
      line = create(:invoice_line_item, invoice: sent_invoice, timesheet_entry: nil)
      tax = create(:invoice_tax, invoice: sent_invoice)
      close_admission!

      expect_refused_without_billing_writes do
        send_request :patch, api_v1_invoice_path(sent_invoice), params: {
          invoice: invoice_attributes(sent_invoice, reference: "fenced",
            invoice_line_items_attributes: [{ id: line.id, rate: 999 }],
            invoice_taxes_attributes: [{ id: tax.id, _destroy: true }])
        }, headers: auth_headers(tenant_a.admin)
      end
    end

    it "refuses a sent invoice discard and a bulk hard delete" do
      close_admission!

      expect_refused_without_billing_writes do
        send_request :delete, api_v1_invoice_path(id: sent_invoice.id), headers: auth_headers(tenant_a.admin)
      end
      expect_refused_without_billing_writes do
        send_request :post, api_v1_invoices_bulk_deletion_index_path,
          params: { invoices_ids: [sent_invoice.id] }, headers: auth_headers(tenant_a.admin)
      end
    end
  end

  describe "payments" do
    it "refuses a manual payment" do
      sign_in tenant_a.admin
      close_admission!

      expect_refused_without_billing_writes do
        send_request :post, api_v1_payments_path(payment: {
          invoice_id: sent_invoice.id, transaction_date: Date.current, transaction_type: "visa", amount: 100
        }), headers: auth_headers(tenant_a.admin)
      end
      expect(sent_invoice.reload.status).to eq("sent")
    end

    it "refuses the payment mailer's sent stamp, so no mail goes out and it can be sent again" do
      close_admission!

      expect {
        PaymentMailer.with(invoice_id: sent_invoice.id).payment.deliver_now
      }.to raise_error(Timekeeping::Ownership::Moving)
      expect(sent_invoice.reload.payment_sent_at).to be_nil
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe "mobile collections" do
    let(:company) { create(:india_company, base_currency: "INR", plan_tier: "paid") }
    let(:collector) { member_of(company, role: :employee) }

    it "refuses a collection with a manual payment, and keeps no client, invoice or payment" do
      sign_in collector
      close_admission!

      expect_refused_without_billing_writes do
        post "/api/v1/mobile/collections",
          params: { collection: { amount: "1800", name: "Asha Rao", payment_method: "cash", phone: "9876543210" } },
          headers: auth_headers(collector)
      end
      expect(User.where(phone: "+919876543210")).to be_empty
    end
  end
end
