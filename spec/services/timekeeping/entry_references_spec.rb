# frozen_string_literal: true

require "rails_helper"

# Where billing's line-item checks read the entries a line references
# (docs/architecture/timekeeping-soa.md §3.3 rule 1, §5.3, §6.3, L8): the
# entries table, as today, or inside an owner's prepared save the owner's
# prepare answer, authoritative for existence and company, with the line-item
# checks kept as the second check.
RSpec.describe Timekeeping::EntryReferences do
  include_context "with two Timekeeping tenants"

  let(:invoice) { invoice_for(tenant_a) }
  let(:entry) { unbilled_entry(tenant_a) }
  let(:unprojected_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }

  def prepared(id, company_id: tenant_a.company.id)
    Timekeeping::ReservationClient::PreparedEntry.new(
      id:, company_id:, project_id: tenant_a.project.id, user_id: tenant_a.employee.id,
      duration: 90.7, work_date: Date.current.iso8601, version: 1
    )
  end

  def direct(entry_id)
    build(:invoice_line_item, invoice:, timesheet_entry_id: entry_id, quantity: 60, rate: 100)
  end

  def grouped(entry_ids)
    build(:invoice_line_item, invoice:, timesheet_entry: nil, quantity: 60, rate: 100).tap do |line|
      line.linked_timesheet_entry_ids = entry_ids
    end
  end

  describe ".current" do
    it "is the entries table outside a prepared save, and the prepared entries inside one" do
      expect(described_class.current).to eq(described_class::Table)

      described_class.within([prepared(unprojected_id)]) do
        expect(described_class.current.find([unprojected_id, entry.id]))
          .to eq(unprojected_id => described_class::Reference.new(id: unprojected_id, company_id: tenant_a.company.id))
      end

      expect(described_class.current).to eq(described_class::Table)
    end

    it "restores the outer source when the block raises" do
      expect { described_class.within([]) { raise ArgumentError } }.to raise_error(ArgumentError)

      expect(described_class.current).to eq(described_class::Table)
    end
  end

  describe described_class::Table do
    it "reads each entry's company from the table and leaves out ids it does not hold" do
      expect(described_class.find([entry.id, unprojected_id]))
        .to eq(entry.id => Timekeeping::EntryReferences::Reference.new(id: entry.id, company_id: tenant_a.company.id))
    end
  end

  describe "the line-item checks inside an owner's prepared save" do
    it "accept a direct and a grouped line naming an entry only the owner holds" do
      described_class.within([prepared(unprojected_id), prepared(unprojected_id + 1)]) do
        expect(direct(unprojected_id)).to be_valid
        line = grouped([unprojected_id, unprojected_id + 1])
        expect(line).to be_valid
        expect(line.linked_timesheet_entry_ids).to eq([unprojected_id, unprojected_id + 1])
      end
    end

    it "refuse an entry the owner did not prepare, even one the table holds" do
      described_class.within([]) do
        expect(direct(entry.id).tap(&:validate).errors.full_messages).to eq(["Timesheet entry must exist"])
        expect(grouped([entry.id]).tap(&:validate).errors.full_messages).to eq(["Invoice line item time entries is invalid"])
      end
    end

    it "keep the company check, on the company the owner answered (L8)" do
      other = tenant_b.company.id

      described_class.within([prepared(entry.id, company_id: other)]) do
        expect(direct(entry.id).tap(&:validate).errors.full_messages).to eq(["Timesheet entry must belong to the same company"])
        line = grouped([entry.id])
        expect(line.tap(&:validate).errors.full_messages)
          .to include("Linked timesheet entries must belong to the same company")
        expect(line.invoice_line_item_time_entries.sole.tap(&:validate).errors.full_messages)
          .to eq(["Timesheet entry must belong to the same company"])
      end
    end

    it "link a saved line by id, keeping the join rows it already held and dropping the rest" do
      line = grouped_line(invoice, [entry])
      held = line.invoice_line_item_time_entries.sole
      rows = -> { line.invoice_line_item_time_entries.reload.order(:id).pluck(:id, :timesheet_entry_id) }

      described_class.within([prepared(entry.id), prepared(unprojected_id)]) do
        line.reload.linked_timesheet_entry_ids = [entry.id.to_s, "", unprojected_id.to_s]
        expect(rows.call.first).to eq([held.id, entry.id])
        expect(rows.call.map(&:last)).to eq([entry.id, unprojected_id])

        line.reload.linked_timesheet_entry_ids = [unprojected_id]
        expect(rows.call.map(&:last)).to eq([unprojected_id])
      end
    end
  end

  describe "the line-item checks outside a prepared save" do
    it "read the table, as before: a missing entry must exist, and a grouped line naming one raises not found" do
      expect(direct(unprojected_id).tap(&:validate).errors.full_messages).to eq(["Timesheet entry must exist"])
      expect { grouped([entry.id, unprojected_id]) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(direct(unbilled_entry(tenant_b).id).tap(&:validate).errors.full_messages).to eq(["Timesheet entry must belong to the same company"])
    end
  end
end
