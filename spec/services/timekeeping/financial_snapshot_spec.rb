# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §13 item 2 and the "Money" row of the
# §10.4 reconciliation: financial parity is proven by snapshot, not by the
# audit log. Both tenants, kept and discarded invoices.
RSpec.describe Timekeeping::FinancialSnapshot, type: :model do
  include_context "with two Timekeeping tenants"

  # K11's line: 19 minutes at 33.33 is stored as 10.55 and printed as $10.56.
  let!(:invoice) do
    invoice_for(tenant_a).tap do |draft|
      create(:invoice_line_item, invoice: draft, timesheet_entry: unbilled_entry(tenant_a, duration: 19), quantity: 19, rate: 33.33)
      draft.reload
    end
  end
  let!(:line) { invoice.invoice_line_items.sole }
  let!(:invoice_tax) do
    create(:invoice_tax, invoice:, amount: 1.25, tax_configuration: create(:tax_configuration, company: tenant_a.company))
  end
  let!(:discarded_invoice) do
    invoice_for(tenant_b, status: :sent).tap do |sent|
      direct_line(sent, unbilled_entry(tenant_b, duration: 90), rate: 50)
      sent.reload.discard!
    end
  end

  def snapshot
    described_class.process
  end

  def differences(before)
    described_class.diff(before, snapshot)
  end

  def writes_while
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe ".process" do
    it "captures every value §13 item 2 names, at column scale, for kept and discarded invoices of both tenants" do
      captured = snapshot

      aggregate_failures do
        expect(captured.keys).to contain_exactly("invoices", "invoice_line_items", "invoice_taxes", "invoice_pdf_totals")
        expect(captured.fetch("invoices").keys).to eq([invoice.id.to_s, discarded_invoice.id.to_s])
        expect(captured.fetch("invoices").fetch(invoice.id.to_s)).to eq(
          "amount" => "10.55",
          "tax" => "0.00",
          "discount" => "0.00",
          "outstanding_amount" => "10.55"
        )
        expect(captured.fetch("invoice_line_items").fetch(line.id.to_s))
          .to eq("invoice_id" => invoice.id.to_s, "rate" => "33.33", "quantity" => "19")
        expect(captured.fetch("invoice_taxes").fetch(invoice_tax.id.to_s)).to eq(
          "invoice_id" => invoice.id.to_s,
          "tax_configuration_id" => invoice_tax.tax_configuration_id.to_s,
          "name" => invoice_tax.name,
          "calculation_method" => InvoiceTax.calculation_methods.fetch(invoice_tax.calculation_method).to_s,
          "value" => format("%.4f", invoice_tax.reload.value),
          "amount" => "1.25"
        )
        expect(captured.fetch("invoice_line_items").values.pluck("invoice_id")).to include(discarded_invoice.id.to_s)
      end
    end

    it "takes the PDF totals from the PDF's own code, so it records the printed total, not the stored amount (M1, K11)" do
      printed = snapshot.fetch("invoice_pdf_totals")
      locals = PdfGeneration::InvoiceService.new(invoice.reload).locals

      aggregate_failures do
        expect(printed.fetch(invoice.id.to_s)).to eq("sub_total" => locals[:sub_total], "total" => locals[:total])
        expect(printed.fetch(invoice.id.to_s).fetch("sub_total")).to eq("$10.56")
        expect(snapshot.fetch("invoices").fetch(invoice.id.to_s).fetch("amount")).not_to eq("10.56")
        expect(printed.fetch(discarded_invoice.id.to_s)).to eq("sub_total" => "$75.00", "total" => "$75.00")
      end
    end

    it "writes nothing" do
      expect(writes_while { snapshot }).to be_empty
    end

    it "survives a JSON round trip unchanged, so a resumed handoff can compare against it" do
      before = JSON.parse(JSON.generate(snapshot))

      expect(described_class.diff(before, snapshot)).to be_empty
    end
  end

  describe ".diff" do
    it "is empty when nothing changed" do
      expect(differences(snapshot)).to be_empty
    end

    it "names each changed stored value, with both sides" do
      before = snapshot
      Invoice.where(id: invoice.id).update_all(discount: 1, outstanding_amount: 9.55)
      InvoiceTax.where(id: invoice_tax.id).update_all(amount: 1.26)

      expect(differences(before)).to contain_exactly(
        described_class::Difference.new(table: "invoices", id: invoice.id.to_s, column: "discount", before: "0.00", after: "1.00"),
        described_class::Difference.new(
          table: "invoices", id: invoice.id.to_s, column: "outstanding_amount",
          before: before.dig("invoices", invoice.id.to_s, "outstanding_amount"), after: "9.55"
        ),
        described_class::Difference.new(table: "invoice_taxes", id: invoice_tax.id.to_s, column: "amount", before: "1.25", after: "1.26"),
        described_class::Difference.new(
          table: "invoice_pdf_totals", id: invoice.id.to_s, column: "total",
          before: before.dig("invoice_pdf_totals", invoice.id.to_s, "total"), after: "$9.56"
        )
      )
    end

    it "catches a changed line rate or quantity, and the printed totals that move with it" do
      before = snapshot
      InvoiceLineItem.where(id: line.id).update_all(quantity: 20)

      expect(differences(before).map { |difference| [difference.table, difference.column, difference.after] })
        .to contain_exactly(
          ["invoice_line_items", "quantity", "20"],
          ["invoice_pdf_totals", "sub_total", "$11.11"],
          ["invoice_pdf_totals", "total", "$11.11"]
        )
    end

    it "reports a row present on only one side as a whole row" do
      before = snapshot
      removed = before.dig("invoice_line_items", line.id.to_s)
      InvoiceLineItem.where(id: line.id).delete_all

      expect(differences(before)).to include(
        described_class::Difference.new(table: "invoice_line_items", id: line.id.to_s, column: nil, before: removed, after: nil)
      )
    end

    it "orders differences by table, then numerically by id" do
      before = { "invoices" => { "10" => { "amount" => "1.00" }, "9" => { "amount" => "1.00" } } }
      after = { "invoices" => { "10" => { "amount" => "2.00" }, "9" => { "amount" => "2.00" } } }

      expect(described_class.diff(before, after).map(&:id)).to eq(%w[9 10])
    end
  end
end
