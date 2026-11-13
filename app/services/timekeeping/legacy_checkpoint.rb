# frozen_string_literal: true

# The checkpoint of the first cutover, taken from the legacy owner
# (docs/architecture/timekeeping-soa.md §10.5 step 4): every entry as a full
# snapshot, and the reservation each one becomes (§7.4). It is what the
# handoff tool loads into Timekeeping and reconciles against this source
# (§10.4, §10.5 step 6).
#
# It runs only while this application's ownership record is frozen under the
# legacy owner at the handoff's generation, and holds the record FOR SHARE
# while it reads, so the handoff cannot abort and reopen admission under it.
# Frozen, nothing writes entries or invoices (§10.1), so what it reads is the
# state the handoff moves.
#
# It writes nothing and normalizes nothing (§10.4). Each entry is mapped by
# the pre-flight (Timekeeping::Preflight), and an item the pre-flight lists
# without a recorded disposition stops the cutover: Undisposed, and no
# checkpoint is taken. The recorded disposition this takes is the one the
# seed disposition records (spec/fixtures/timekeeping/seed_disposition.yml):
# the kept invoices whose unlocked links map to an active reservation with no
# edit lock. No disposition is defined for an orphan or a conflict, so any
# one of them stops the cutover.
#
# Values are copied as stored (§8 item 1): duration stays the float it is,
# timestamps keep their microseconds, and no model callback runs.
class Timekeeping::LegacyCheckpoint
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # The pre-flight listed an item with no recorded disposition (§10.4). Nothing
  # was taken. `lists` names each list and the entry ids on it.
  class Undisposed < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint: no recorded disposition for #{lists.map { |name, ids| "#{name} #{ids.join(', ')}" }.join('; ')}; nothing taken")
    end
  end

  Checkpoint = Data.define(:generation, :entries, :reservations) do
    # The id the incoming owner's sequence is set above (§10.3); nil when
    # there is no entry.
    def highest_entry_id = entries.map { |entry| entry.fetch("id") }.max
  end

  # The reservation each pre-flight mapping becomes at the first cutover
  # (§7.4), committed, or none. An orphan and a conflict have no row: they
  # never reach this table (Undisposed).
  RESERVATIONS = {
    active: ->(entry) { { invoice_id: entry.kept_invoice_ids.sole, disposition: :active, edit_lock: entry.locked } },
    retained: ->(entry) { { invoice_id: entry.discarded_invoice_ids.sole, disposition: :retained, edit_lock: true } },
    released: ->(_) { nil },
    none: ->(_) { nil }
  }.freeze

  def self.take(generation:, unlocked_link_invoice_ids: [])
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen_legacy!(:checkpoint, generation)
      report = Timekeeping::Preflight.process
      ensure_disposed!(report, unlocked_link_invoice_ids.to_set)

      reservations = report.entries.filter_map { |entry| reservation_for(entry) }
      Checkpoint.new(generation:, entries: entries(reservations), reservations:)
    end
  end

  def self.ensure_disposed!(report, unlocked_link_invoice_ids)
    lists = {
      orphans: report.orphans,
      conflicts: report.conflicts,
      unlocked_links: report.unlocked_links.reject { |entry| unlocked_link_invoice_ids.superset?(entry.kept_invoice_ids.to_set) }
    }.transform_values { |entries| entries.map(&:entry_id) }.reject { |_, ids| ids.empty? }

    raise Undisposed, lists if lists.any?
  end
  private_class_method :ensure_disposed!

  def self.reservation_for(entry)
    RESERVATIONS.fetch(entry.mapping).call(entry)&.then do |reservation|
      TimekeepingReservations::Reservation.new(
        entry_id: entry.entry_id, company_id: entry.company_id, operation_id: nil, state: :committed, **reservation
      )
    end
  end
  private_class_method :reservation_for

  # Every entry, discarded ones included, as common.json#/$defs/entry
  # (Timekeeping::StoredEntries). Its version is the next one, the first
  # Timekeeping holds: a legacy row is at 0, so the incoming owner's snapshot
  # of it replaces the projection's row (§3.2). `locked` is derived from its
  # reservation by the shared rule (§7.1), so an F2 release reads unlocked.
  def self.entries(reservations)
    by_entry = reservations.group_by(&:entry_id)

    Timekeeping::StoredEntries.all.map do |entry|
      id = entry.fetch("id")
      entry.merge("version" => entry.fetch("version") + 1, "locked" => TimekeepingReservations.locked?(id, by_entry.fetch(id, [])))
    end
  end
  private_class_method :entries
end
