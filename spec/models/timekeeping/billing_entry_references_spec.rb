# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §10.2 step 3: the two foreign keys from
# billing to entries are dropped before cutover, so a line item can name an
# entry the projection does not hold yet. The models still refuse an entry id
# that names no entry.
RSpec.describe "Timekeeping: billing references to entries", type: :model do
  include_context "with two Timekeeping tenants"

  let(:connection) { ActiveRecord::Base.connection }
  let(:entry) { unbilled_entry(tenant_a) }
  let(:invoice) { invoice_for(tenant_a) }
  let(:missing_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  def keys_to(table, target)
    connection.foreign_keys(table).select { |key| key.to_table == target }
  end

  describe "the schema" do
    it "has no key from line items or their links to timesheet_entries" do
      expect(keys_to("invoice_line_items", "timesheet_entries")).to be_empty
      expect(keys_to("invoice_line_item_time_entries", "timesheet_entries")).to be_empty
    end

    it "keeps the indexes those keys used and every other key on these tables" do
      expect(connection.index_exists?(:invoice_line_items, :timesheet_entry_id)).to be(true)
      expect(connection.index_exists?(:invoice_line_item_time_entries, :timesheet_entry_id)).to be(true)
      expect(keys_to("invoice_line_items", "invoices").size).to eq(1)
      expect(keys_to("invoice_line_item_time_entries", "invoice_line_items").size).to eq(1)
      expect(keys_to("timesheet_entries", "users").size).to eq(1)
    end

    it "lets the database hold a line and a link for an entry the projection does not hold yet" do
      line_id = InvoiceLineItem.insert!(
        { invoice_id: invoice.id, timesheet_entry_id: missing_id, name: "Work", date: Date.current, rate: 100, quantity: 60 }
      ).rows.sole.first
      InvoiceLineItemTimeEntry.insert!({ invoice_line_item_id: line_id, timesheet_entry_id: missing_id })

      expect(InvoiceLineItem.where(timesheet_entry_id: missing_id).count).to eq(1)
      expect(InvoiceLineItemTimeEntry.where(timesheet_entry_id: missing_id).count).to eq(1)
    end
  end

  describe "the models" do
    def line(timesheet_entry_id)
      build(:invoice_line_item, invoice:, timesheet_entry_id:, quantity: 60, rate: 100)
    end

    it "refuses a direct line naming no entry" do
      line = line(missing_id)

      expect(line).not_to be_valid
      expect(line.errors.full_messages).to eq(["Timesheet entry must exist"])
    end

    it "accepts a direct line for an existing entry, and a line with no direct entry" do
      expect(line(entry.id)).to be_valid
      expect(line(nil)).to be_valid
    end

    it "refuses a grouped line's link naming no entry" do
      link = build(:invoice_line_item_time_entry, invoice_line_item: grouped_line(invoice, [entry]), timesheet_entry_id: missing_id)

      expect(link).not_to be_valid
      expect(link.errors.full_messages).to eq(["Timesheet entry must exist"])
    end

    it "still refuses an entry of another company (L8)" do
      line = line(unbilled_entry(tenant_b).id)

      expect(line).not_to be_valid
      expect(line.errors.full_messages).to eq(["Timesheet entry must belong to the same company"])
    end
  end
end
