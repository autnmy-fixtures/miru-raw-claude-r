# frozen_string_literal: true

# The desired set of docs/architecture/timekeeping-soa.md §7.2 for an invoice
# save, worked out before the save runs: "every entry still referenced by the
# invoice's remaining direct and grouped lines". Prepare needs it before the
# invoice transaction opens (§9.2 step 2), and the save cannot be assigned
# first to read it back: writing linked_timesheet_entry_ids on a persisted
# line item changes its join rows at once, outside any transaction.
#
# Pure apart from .lines_of. It follows accepts_nested_attributes_for as
# Invoice declares it (allow_destroy: true): a posted line with an id changes
# that line, or removes it when `_destroy` is set; a line without an id is
# added unless `_destroy` is set. Only the keys a line posts replace what it
# held. A posted id the invoice does not hold changes nothing here; the save
# itself refuses it.
module Timekeeping::InvoiceDesiredSet
  # One line as the invoice holds it before the save.
  Line = Data.define(:id, :timesheet_entry_id, :linked_ids)

  NEW_LINE = Line.new(id: nil, timesheet_entry_id: nil, linked_ids: [])
  BOOLEAN = ActiveModel::Type::Boolean.new
  ID = ActiveModel::Type::Integer.new

  # The persisted lines of an invoice, with their linked entries, in two
  # queries.
  def self.lines_of(invoice)
    return [] unless invoice&.persisted?

    linked = InvoiceLineItemTimeEntry
      .joins(:invoice_line_item).where(invoice_line_items: { invoice_id: invoice.id })
      .pluck(:invoice_line_item_id, :timesheet_entry_id)
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }

    InvoiceLineItem.where(invoice_id: invoice.id).pluck(:id, :timesheet_entry_id).map do |id, entry_id|
      Line.new(id:, timesheet_entry_id: entry_id, linked_ids: linked.fetch(id, []))
    end
  end

  # The entry ids `lines` reference once `posted` (a request's
  # invoice_line_items_attributes, or nil) is applied. Sorted, unique.
  def self.after(lines, posted)
    kept = lines.index_by(&:id)
    added = []
    collection(posted).each do |attributes|
      id = ID.cast(attributes["id"].presence)
      destroy = BOOLEAN.cast(attributes["_destroy"])
      if id.nil?
        added << posted_line(NEW_LINE, attributes) unless destroy
      elsif kept.key?(id)
        destroy ? kept.delete(id) : kept[id] = posted_line(kept.fetch(id), attributes)
      end
    end
    entry_ids(kept.values + added)
  end

  # The entry ids an invoice's persisted lines reference now.
  def self.referenced(invoice)
    entry_ids(lines_of(invoice))
  end

  # :draft or :non_draft, as the reservation rule reads an invoice state.
  def self.invoice_state(status)
    status.to_s == "draft" ? :draft : :non_draft
  end

  def self.entry_ids(lines)
    lines.flat_map { |line| [line.timesheet_entry_id, *line.linked_ids] }.compact.uniq.sort
  end

  # Nested attributes arrive as an array, as a hash keyed by index, or as one
  # line's hash: the three forms accepts_nested_attributes_for takes.
  def self.collection(posted)
    lines =
      case posted
      when nil then []
      when Hash then posted.key?("id") || posted.key?(:id) ? [posted] : posted.values
      else Array(posted)
      end
    lines.map { |attributes| attributes.to_h.stringify_keys }
  end

  def self.posted_line(line, attributes)
    line.with(
      timesheet_entry_id: posted_id(attributes, line),
      linked_ids: posted_linked_ids(attributes, line)
    )
  end

  def self.posted_id(attributes, line)
    return line.timesheet_entry_id unless attributes.key?("timesheet_entry_id")

    ID.cast(attributes["timesheet_entry_id"].presence)
  end

  # As has_many :through ids= reads them: blanks dropped, each cast.
  def self.posted_linked_ids(attributes, line)
    return line.linked_ids unless attributes.key?("linked_timesheet_entry_ids")

    Array(attributes["linked_timesheet_entry_ids"]).compact_blank.map { |id| ID.cast(id) }
  end

  private_class_method :entry_ids, :collection, :posted_line, :posted_id, :posted_linked_ids
end
