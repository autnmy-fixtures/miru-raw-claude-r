# frozen_string_literal: true

# The financial snapshot of docs/architecture/timekeeping-soa.md §13 item 2,
# the "Money" check of the §10.4 reconciliation.
#
# Moving entries between owners must never change a billing value (§8), and
# the audit log cannot prove that (`audited` on Invoice omits discount, tax and
# outstanding_amount; line items and invoice taxes are not audited, §1.6). So
# the handoff takes this snapshot before and after, and the two must be
# identical or the run fails.
#
# It is read-only. Every invoice is captured, kept and discarded, for both
# tenants: the one global handoff moves them all (§10.1). Stored values are
# read as Postgres renders them at column scale (§5.1: money is a decimal
# string at column scale), so a snapshot is plain strings and survives a JSON
# round trip unchanged, and a later step of a resumed handoff can compare
# against one taken before the interruption.
class Timekeeping::FinancialSnapshot < ApplicationService
  # One row per difference. A row present on only one side has no column, and
  # carries the whole row on the side that has it.
  Difference = Data.define(:table, :id, :column, :before, :after)

  # The stored values §13 item 2 names, per table.
  STORED = {
    "invoices" => { model: Invoice, columns: %w[amount tax discount outstanding_amount] },
    "invoice_line_items" => { model: InvoiceLineItem, columns: %w[invoice_id rate quantity] },
    "invoice_taxes" => {
      model: InvoiceTax,
      columns: %w[invoice_id tax_configuration_id name calculation_method value amount]
    }
  }.freeze

  # The rendered PDF totals (M1): what the PDF prints, from the PDF's own code.
  PRINTED = "invoice_pdf_totals"

  # Every difference between two snapshots, ordered by table and id. Empty
  # means identical.
  def self.diff(before, after)
    (before.keys | after.keys).sort.flat_map do |table|
      rows_before = before.fetch(table, {})
      rows_after = after.fetch(table, {})

      (rows_before.keys | rows_after.keys).sort_by(&:to_i).flat_map do |id|
        row_differences(table, id, rows_before[id], rows_after[id])
      end
    end
  end

  def self.row_differences(table, id, before, after)
    return [Difference.new(table:, id:, column: nil, before:, after:)] if before.nil? || after.nil?

    (before.keys | after.keys).filter_map do |column|
      Difference.new(table:, id:, column:, before: before[column], after: after[column]) if before[column] != after[column]
    end
  end
  private_class_method :row_differences

  def process
    STORED.transform_values { |table| stored_rows(**table) }.merge(PRINTED => printed_rows)
  end

  private

    # select_rows, not pluck: pluck casts a result column back through the
    # attribute of the same name, which would turn the text back into a
    # BigDecimal or Integer.
    def stored_rows(model:, columns:)
      as_text = (["id"] + columns).map { |column| "#{model.quoted_table_name}.#{model.connection.quote_column_name(column)}::text" }
      query = model.unscoped.order(:id).select(*as_text.map { |sql| Arel.sql(sql) })

      model.connection.select_rows(query.to_sql).to_h do |id, *values|
        [id, columns.zip(values).to_h]
      end
    end

    def printed_rows
      Invoice.unscoped.find_each.to_h do |invoice|
        [invoice.id.to_s, PdfGeneration::InvoiceService.printed_totals(invoice).stringify_keys]
      end
    end
end
