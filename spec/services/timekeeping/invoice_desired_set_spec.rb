# frozen_string_literal: true

require "rails_helper"

# The desired set of docs/architecture/timekeeping-soa.md §7.2, worked out
# from an invoice's lines and the posted nested line attributes before the
# save runs: every entry still referenced by the remaining direct and grouped
# lines.
RSpec.describe Timekeeping::InvoiceDesiredSet do
  def line(id, direct, linked = [])
    described_class::Line.new(id:, timesheet_entry_id: direct, linked_ids: linked)
  end

  describe ".after" do
    let(:lines) { [line(1, 10), line(2, nil, [10, 11])] }

    it "keeps every line when nothing is posted" do
      expect(described_class.after(lines, nil)).to eq([10, 11])
    end

    it "adds the direct and linked entries of a new line, posted as params send them" do
      posted = [
        { "name" => "Direct", "timesheet_entry_id" => "12" },
        { "name" => "Grouped", "linked_timesheet_entry_ids" => ["", "13", "14"] }
      ]

      expect(described_class.after(lines, posted)).to eq([10, 11, 12, 13, 14])
    end

    it "keeps an entry another line still references when a grouped line is removed (F3)" do
      expect(described_class.after(lines, [{ "id" => "2", "_destroy" => "1" }])).to eq([10])
    end

    it "removes every entry once no line references it" do
      posted = [{ "id" => 1, "_destroy" => true }, { "id" => 2, "_destroy" => "true" }]

      expect(described_class.after(lines, posted)).to eq([])
    end

    it "replaces only the keys a posted line carries" do
      posted = [{ "id" => 1, "quantity" => 30 }, { "id" => 2, "linked_timesheet_entry_ids" => ["15"] }]

      expect(described_class.after(lines, posted)).to eq([10, 15])
    end

    it "clears a line's direct entry posted blank" do
      expect(described_class.after(lines, [{ "id" => 1, "timesheet_entry_id" => "" }])).to eq([10, 11])
      expect(described_class.after([line(1, 10)], [{ "id" => 1, "timesheet_entry_id" => "" }])).to eq([])
    end

    it "ignores a new line posted for destruction, and a posted id the invoice does not hold" do
      posted = [{ "timesheet_entry_id" => 20, "_destroy" => "1" }, { "id" => 99, "timesheet_entry_id" => 21 }]

      expect(described_class.after(lines, posted)).to eq([10, 11])
    end

    it "reads the hash forms of nested attributes" do
      expect(described_class.after(lines, { "0" => { "id" => 2, "_destroy" => "1" }, "1" => { "timesheet_entry_id" => 12 } }))
        .to eq([10, 12])
      expect(described_class.after(lines, { "id" => 1, "_destroy" => "1" })).to eq([10, 11])
      expect(described_class.after(lines, { id: 1, _destroy: "1" })).to eq([10, 11])
    end
  end

  describe ".lines_of and .referenced" do
    let(:company) { create(:company) }
    let(:client) { create(:client, company:) }
    let(:project) { create(:project, client:) }
    let(:invoice) { create(:invoice, company:, client:) }
    let(:entries) { create_list(:timesheet_entry, 3, project:) }

    it "reads each persisted line with its linked entries" do
      direct = create(:invoice_line_item, invoice:, timesheet_entry: entries[0])
      grouped = create(:invoice_line_item, invoice:, timesheet_entry: nil)
      entries.first(2).each { |entry| create(:invoice_line_item_time_entry, invoice_line_item: grouped, timesheet_entry: entry) }
      create(:invoice_line_item, invoice: create(:invoice, company:, client:), timesheet_entry: entries[2])

      read = described_class.lines_of(invoice).map { |held| held.with(linked_ids: held.linked_ids.sort) }
      expect(read).to contain_exactly(line(direct.id, entries[0].id), line(grouped.id, nil, entries.first(2).map(&:id).sort))
      expect(described_class.referenced(invoice)).to eq(entries.first(2).map(&:id).sort)
    end

    it "has no lines for an invoice not yet saved" do
      expect(described_class.lines_of(Invoice.new)).to eq([])
    end
  end

  describe ".invoice_state" do
    it "reads draft as draft and every other status as non-draft" do
      expect(described_class.invoice_state("draft")).to eq(:draft)
      expect(Invoice.statuses.keys.excluding("draft").map { |status| described_class.invoice_state(status) }.uniq).to eq([:non_draft])
    end
  end
end
