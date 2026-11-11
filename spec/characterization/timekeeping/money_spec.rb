# frozen_string_literal: true

require "rails_helper"

# Characterization: pins how stored invoice totals and PDF totals are computed
# today (docs/architecture/timekeeping-soa.md §1.6, §2.4 M1/M2, Appendix A K11).
# The extraction must not change any of these values.
RSpec.describe "Timekeeping characterization: money", type: :model do
  include_context "with two Timekeeping tenants"

  let(:invoice) { invoice_for(tenant_a) }

  before do
    allow_any_instance_of(ActionController::Base).to receive(:render_to_string)
      .and_return("<html><body>invoice</body></html>")
    create(:invoice_line_item, invoice:, timesheet_entry: unbilled_entry(tenant_a, duration: 19), quantity: 19, rate: 33.33)
    invoice.reload
  end

  it "M2: stores the subtotal in Float arithmetic rounded to 2 dp" do
    expect(invoice.amount.to_f).to eq(10.55)
    expect(invoice.amount_due.to_f).to eq(10.55)
  end

  it "M1 / K11: prints a PDF total recomputed with round(3), so it differs from the stored amount" do
    locals = PdfGeneration::InvoiceService.new(invoice).locals

    expect(invoice.invoice_line_items.total_cost_of_all_line_items).to eq(BigDecimal("10.555"))
    expect(locals[:total]).to eq("$10.56")
    expect(locals[:invoice_amount]).to eq("$10.55")
  end

  # Float hours (19 / 60.0) times the rate gives 10.55449..., so the line
  # total rounds down while the SQL subtotal above rounds up: one line, three
  # values (stored 10.55, line 10.554, PDF subtotal 10.555).
  it "M1: line total_cost rounds Float (quantity / 60) * rate to 3 dp, below the PDF subtotal" do
    expect(invoice.invoice_line_items.sole.total_cost).to eq(BigDecimal("10.554"))
  end
end
