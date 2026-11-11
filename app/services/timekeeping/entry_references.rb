# frozen_string_literal: true

# Where billing reads what it checks about the entries an invoice line
# references, and how a grouped line links them (docs/architecture/
# timekeeping-soa.md §3.3 rule 1, §6.3, L8).
#
# Two sources, one interface:
#
# - Table, today's and the one outside an owner's prepared save: the
#   entries table, read exactly as the line-item checks read it before.
# - Prepared, inside an invoice save an owner prepared (§9.2 step 3): the
#   prepare response, authoritative for existence and same-company (§5.3).
#   The line-item checks stay as the second check, with the company the owner
#   answered. A grouped line links its entries by id, because loading them
#   is a read of the projection, which may not hold an entry yet (§3.3 rule 2).
#
# With the prepared source, an entry Timekeeping owns can be invoiced before
# the relay has projected it (§12.4 "relay paused").
module Timekeeping::EntryReferences
  # What the checks need about one entry.
  Reference = Data.define(:id, :company_id)

  KEY = :timekeeping_entry_references
  private_constant :KEY

  # Entry ids as has_many :through ids= reads them: blanks dropped, each cast.
  def self.cast(ids)
    type = TimesheetEntry.type_for_attribute(TimesheetEntry.primary_key)
    Array(ids).compact_blank.map { |id| type.cast(id) }
  end

  module Table
    # The References of the ids found in the entries table, by id.
    def self.find(ids)
      TimesheetEntry.where(id: ids).preload(:company).to_h do |entry|
        [entry.id, Reference.new(id: entry.id, company_id: entry.company&.id)]
      end
    end

    # Today's has_many :through writer: an id naming no entry raises
    # ActiveRecord::RecordNotFound.
    def self.link(line, ids)
      line.association(:linked_timesheet_entries).ids_writer(ids)
    end
  end

  class Prepared
    def initialize(entries)
      @references = entries.to_h { |entry| [entry.id, Reference.new(id: entry.id, company_id: entry.company_id)] }.freeze
    end

    def find(ids)
      @references.slice(*ids)
    end

    # The line's join rows become one per id, keeping the rows it already
    # holds. A persisted line changes its rows at once, as the :through
    # writer does; a new line saves them with itself.
    def link(line, ids)
      rows = line.invoice_line_item_time_entries.to_a
      line.invoice_line_item_time_entries = Timekeeping::EntryReferences.cast(ids).map do |id|
        rows.find { |row| row.timesheet_entry_id == id } || InvoiceLineItemTimeEntry.new(timesheet_entry_id: id)
      end
      line.association(:linked_timesheet_entries).reset
    end
  end

  # The source for this execution context.
  def self.current
    ActiveSupport::IsolatedExecutionState[KEY] || Table
  end

  # Runs the block with the prepared entries of an owner as the source.
  def self.within(prepared_entries)
    outer = ActiveSupport::IsolatedExecutionState[KEY]
    ActiveSupport::IsolatedExecutionState[KEY] = Prepared.new(prepared_entries)
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[KEY] = outer
  end
end
