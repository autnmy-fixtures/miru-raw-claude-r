# frozen_string_literal: true

# The read-only pre-flight of docs/architecture/timekeeping-soa.md §10.4.
#
# It reads every entry and the invoices that reference it, directly or through
# a grouped line, and maps the entry to the reservation it becomes at the first
# cutover (§7.4). It writes nothing and normalizes nothing: orphans, conflicts,
# retained entries, F2 releases and unlocked links are listed so that each one
# gets a recorded disposition.
class Timekeeping::Preflight < ApplicationService
  # An entry's billing references, counted per distinct invoice and bucketed
  # as :none, :one or :many.
  Facts = Data.define(:kept, :locked, :discarded_non_drafts, :discarded_drafts)

  Reference = Data.define(:invoice_id, :kept, :draft)

  Entry = Data.define(:entry_id, :company_id, :locked, :mapping, :kept_invoice_ids, :discarded_invoice_ids) do
    # Referenced by a kept invoice, yet no draft save ever locked it (L1).
    def unlocked_link?
      mapping == :active && !locked
    end
  end

  Report = Data.define(:entries) do
    def orphans = with_mapping(:orphan)
    def conflicts = with_mapping(:conflict)
    def retained = with_mapping(:retained)
    def released = with_mapping(:released)
    def unlocked_links = entries.select(&:unlocked_link?)

    private

      def with_mapping(mapping)
        entries.select { |entry| entry.mapping == mapping }
      end
  end

  # §7.4, one row per line of its table, first match wins.
  def self.mapping_for(facts)
    case [facts.kept, facts.locked, facts.discarded_non_drafts, facts.discarded_drafts]
    in [:many, _, _, _] then :conflict                 # on two or more kept invoices
    in [:one, _, _, _] then :active                    # committed, active; edit_lock = locked
    in [:none, false, _, _] then :none                 # nothing reserves or locks it today
    in [:none, true, :none, :none] then :orphan        # locked, referenced by no invoice
    in [:none, true, :one, :none] then :retained       # held by one discarded non-draft (L3)
    in [:none, true, :none, :one | :many] then :released # draft-discard re-lock only (F2)
    in [:none, true, _, _] then :conflict              # more than one plausible historical owner
    end
  end

  def self.bucket(count)
    { 0 => :none, 1 => :one }.fetch(count, :many)
  end

  def process
    references = references_by_entry

    Report.new(
      entries: TimesheetEntry.joins(project: :client).order(:id)
        .pluck(:id, "clients.company_id", :locked)
        .map { |entry_id, company_id, locked| classify(entry_id, company_id, locked, references.fetch(entry_id, [])) }
    )
  end

  private

    def classify(entry_id, company_id, locked, references)
      kept, discarded = references.partition(&:kept)
      drafts, non_drafts = discarded.partition(&:draft)
      facts = Facts.new(
        kept: self.class.bucket(kept.size),
        locked:,
        discarded_non_drafts: self.class.bucket(non_drafts.size),
        discarded_drafts: self.class.bucket(drafts.size)
      )

      Entry.new(
        entry_id:,
        company_id:,
        locked:,
        mapping: self.class.mapping_for(facts),
        kept_invoice_ids: kept.map(&:invoice_id),
        discarded_invoice_ids: discarded.map(&:invoice_id)
      )
    end

    # One row per distinct (entry, invoice) pair, whether the invoice references
    # the entry through a direct line, a grouped line, or both.
    def references_by_entry
      direct = InvoiceLineItem.where.not(timesheet_entry_id: nil)
        .select("invoice_line_items.timesheet_entry_id AS entry_id, invoice_line_items.invoice_id")
      linked = InvoiceLineItemTimeEntry.joins(:invoice_line_item)
        .select("invoice_line_item_time_entries.timesheet_entry_id AS entry_id, invoice_line_items.invoice_id")

      Invoice.joins("JOIN (#{direct.to_sql} UNION #{linked.to_sql}) refs ON refs.invoice_id = invoices.id")
        .distinct
        .pluck("refs.entry_id", :id, :discarded_at, :status)
        .group_by(&:first)
        .transform_values do |rows|
          rows.map { |_, invoice_id, discarded_at, status| Reference.new(invoice_id:, kept: discarded_at.nil?, draft: status == "draft") }
        end
    end
end
