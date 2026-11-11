# frozen_string_literal: true

require "rails_helper"

# The billing-write fence of docs/architecture/timekeeping-soa.md §10.1, model
# by model: while admission is not open, every invoice, line-item, line-item
# link, invoice-tax and payment write is refused with a retryable
# Timekeeping::Ownership::Moving and leaves every billing row as it was.
# While admission is open, in any ownership state, billing writes go through.
RSpec.describe Timekeeping::BillingWriteFence, type: :model do
  include_context "with two Timekeeping tenants"

  let(:entry) { unbilled_entry(tenant_a) }
  # Sent, so no write below reaches the entry lock callbacks and the gateway:
  # what is measured is the billing fence alone.
  let!(:invoice) { invoice_for(tenant_a, status: :sent) }
  let!(:line) { grouped_line(invoice, [entry]) }
  let!(:invoice_tax) { create(:invoice_tax, invoice:) }
  let!(:payment) { create(:payment, invoice:, amount: 10) }

  def billing_rows
    [Invoice, InvoiceLineItem, InvoiceLineItemTimeEntry, InvoiceTax, Payment].to_h { |model| [model.name, model.order(:id).map(&:attributes)] }
  end

  # Each write runs in a savepoint of its own, as a request runs in its own
  # transaction, so a refused one leaves nothing behind for the next.
  def attempt(&write)
    ActiveRecord::Base.transaction(requires_new: true) { write.call }
  end

  def writes
    {
      "invoice create" => -> { create(:invoice, company: tenant_a.company, client: tenant_a.client, status: :sent) },
      "invoice update" => -> { invoice.reload.update!(reference: "fenced") },
      "invoice update_columns" => -> { invoice.reload.update_columns(payment_sent_at: Time.current) },
      "line item create" => -> { create(:invoice_line_item, invoice:, timesheet_entry: nil) },
      "line item update" => -> { line.reload.update!(rate: 999) },
      "line item link create" => -> { create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: unbilled_entry(tenant_a)) },
      "line item link destroy" => -> { line.invoice_line_item_time_entries.first.destroy! },
      "line item destroy" => -> { line.reload.destroy! },
      "invoice tax create" => -> { create(:invoice_tax, invoice:) },
      "invoice tax update" => -> { invoice_tax.reload.update!(name: "Fenced") },
      "invoice tax destroy" => -> { invoice_tax.reload.destroy! },
      "payment create" => -> { create(:payment, invoice:, amount: 5) },
      "payment update" => -> { payment.reload.update!(note: "fenced") },
      "payment destroy" => -> { invoice.payments.reload.each(&:destroy!) },
      "invoice discard" => -> { invoice.reload.discard! },
      "invoice destroy" => -> { Invoice.find(invoice.id).destroy! }
    }
  end

  TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.reject { |_, attributes| attributes[:state] == "open" }.each do |label, attributes|
    context "when #{label}" do
      it "refuses every billing write and leaves every billing row as it was" do
        set_timekeeping_ownership!(attributes)
        before = billing_rows

        writes.each do |name, write|
          expect { attempt(&write) }.to raise_error(Timekeeping::Ownership::Moving, /being moved between services/), name
        end
        expect(billing_rows).to eq(before)
      end
    end
  end

  { "before the first handoff" => TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF }
    .merge(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.select { |_, attributes| attributes[:state] == "open" })
    .each do |label, attributes|
      context "when #{label}" do
        it "admits every billing write" do
          set_timekeeping_ownership!(attributes)

          writes.each do |name, write|
            expect { attempt(&write) }.not_to raise_error, name
          end
        end
      end
    end
end
