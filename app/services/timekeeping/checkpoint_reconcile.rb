# frozen_string_literal: true

# Step 6 of the first cutover on this application's side
# (docs/architecture/timekeeping-soa.md §10.5, §10.4 "Reconciliation"): the
# checkpoint taken from the legacy owner (Timekeeping::LegacyCheckpoint),
# compared with this application's own tables. Timekeeping reconciles what it
# holds against the same checkpoint (services/timekeeping/app/services/
# checkpoint_reconcile.rb); the handoff tool carries the checkpoint to both,
# as the two applications share no database (§11.2).
#
# It covers the rows of §10.4's table that read this application's tables,
# each exact:
#
# - Reservations vs invoices: every (entry, invoice, tenant) a kept invoice
#   references through a direct or a grouped line is one active reservation
#   the checkpoint carries, and every active reservation is such a reference.
#   The first cutover has no listed pre-flight item left to explain a
#   difference: the checkpoint is not taken while an orphan, a conflict or an
#   undisposed unlocked link is listed, and a disposed unlocked link is an
#   active reservation like any other.
# - Projection: timesheet_entries holds exactly the checkpoint's entries, every
#   column of every entry by id, `version` and `locked` included. The
#   checkpoint's entries are what Timekeeping holds once its own reconcile
#   passes, so this is "Timekeeping entries through the final outbox
#   position": the handoff tool calls it only once the relay has delivered
#   every snapshot the load wrote.
# - Money: the financial snapshot (Timekeeping::FinancialSnapshot) taken before
#   the handoff is identical to one taken now.
#
# It runs only while this application's ownership record is frozen under the
# legacy owner at the handoff's generation, and holds the record FOR SHARE
# while it reads, so the handoff cannot flip or abort under it. Frozen,
# nothing writes entries or invoices here (§10.1) apart from the projection
# consumer, the one writer of timesheet_entries.
#
# It writes nothing and explains nothing away: any difference raises Differs,
# and the handoff tool aborts the handoff (§10.5 step 6).
module Timekeeping::CheckpointReconcile
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # This application's tables do not agree with what the handoff carried.
  # `lists` names each check that failed and what it found: entry ids for
  # references and the projection, `table/id/column` (or `table/id` for a row
  # on one side only) for money.
  class Differs < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint reconcile: #{lists.map { |name, found| "#{name} #{found.join(', ')}" }.join('; ')}; abort the handoff")
    end
  end

  Reconciled = Data.define(:entries, :reservations)

  # One side of the comparison. `entries` are common.json#/$defs/entry each,
  # by id; `references` are [entry_id, invoice_id, company_id] triples;
  # `money` is a Timekeeping::FinancialSnapshot.
  State = Data.define(:entries, :references, :money)

  # Each check answers what differs between what the handoff `carried` and
  # what this application `holds`, empty when they agree.
  CHECKS = {
    reference_without_reservation: ->(carried, held) { (held.references - carried.references).map(&:first) },
    reservation_without_reference: ->(carried, held) { (carried.references - held.references).map(&:first) },
    projection_missing: ->(carried, held) { carried.entries.keys - held.entries.keys },
    projection_unexpected: ->(carried, held) { held.entries.keys - carried.entries.keys },
    projection_differs: ->(carried, held) {
      carried.entries.filter_map { |id, entry| id if held.entries.key?(id) && held.entries[id] != entry }
    },
    money_differs: ->(carried, held) {
      Timekeeping::FinancialSnapshot.diff(carried.money, held.money)
        .map { |difference| [difference.table, difference.id, difference.column].compact.join("/") }
    }
  }.freeze

  # Reconciles against `entries` (common.json#/$defs/entry each) and
  # `reservations` (TimekeepingReservations::Reservation values), the
  # checkpoint taken at `generation`, and `financial_snapshot`, the
  # Timekeeping::FinancialSnapshot the handoff tool (Timekeeping::FirstCutover)
  # took once close had drained every billing write already admitted.
  def self.call(generation:, entries:, reservations:, financial_snapshot:)
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen_legacy!(:reconcile, generation)

      ensure_agrees!(carried(entries, reservations, financial_snapshot), held)
      Reconciled.new(entries: entries.size, reservations: reservations.size)
    end
  end

  def self.carried(entries, reservations, financial_snapshot)
    State.new(
      entries: entries.index_by { |entry| entry.fetch("id") },
      references: reservations.select(&:active?).to_set { |reservation| [reservation.entry_id, reservation.invoice_id, reservation.company_id] },
      money: financial_snapshot
    )
  end
  private_class_method :carried

  def self.held
    State.new(
      entries: Timekeeping::StoredEntries.all.index_by { |entry| entry.fetch("id") },
      references: kept_invoice_references,
      money: Timekeeping::FinancialSnapshot.process
    )
  end
  private_class_method :held

  # Every distinct (entry, invoice, tenant) a kept invoice references, through
  # a direct line or a grouped line's links.
  def self.kept_invoice_references
    direct = InvoiceLineItem.joins(:invoice).merge(Invoice.kept).where.not(timesheet_entry_id: nil)
      .pluck(:timesheet_entry_id, :invoice_id, "invoices.company_id")
    linked = InvoiceLineItemTimeEntry.joins(invoice_line_item: :invoice).merge(Invoice.kept)
      .pluck(:timesheet_entry_id, "invoice_line_items.invoice_id", "invoices.company_id")

    (direct + linked).to_set
  end
  private_class_method :kept_invoice_references

  def self.ensure_agrees!(carried, held)
    lists = CHECKS.transform_values { |check| check.call(carried, held).uniq.sort }.reject { |_, found| found.empty? }
    raise Differs, lists if lists.any?
  end
  private_class_method :ensure_agrees!
end
