# frozen_string_literal: true

# Steps 4 and 5 of the first cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.5): the checkpoint the existing
# application took from the legacy owner (Timekeeping::LegacyCheckpoint
# there) loaded into Timekeeping, the incoming owner, and the entries' id
# sequence set above the highest loaded id (§10.3). The handoff tool carries
# the checkpoint across; the two applications share no database (§11.2).
#
# It runs only while Timekeeping's copy of the ownership record is frozen
# under the legacy owner at the handoff's generation, and holds the record
# FOR SHARE while it writes, so the handoff cannot flip or abort under it.
# Frozen, admission refuses every mutating call (Ownership.admit!), so the
# load is the only writer.
#
# One transaction: every entry, every reservation, one outbox snapshot per
# entry, and the sequence, or nothing. Values are copied as the checkpoint
# carries them (§8 item 1): no writer's rule, callback or audit row runs, and
# `updated_at` is kept. Each entry's snapshot carries the version the
# checkpoint gave it and the `locked` its reservations derive, so the relay
# replaces the projection's legacy row with it (§3.2), F2 releases included.
#
# Nothing is normalized (§10.4): a checkpoint that does not hold together is
# refused whole, listing the entry ids each check found.
module CheckpointLoad
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep
  STATES = %w[frozen].freeze

  # The checkpoint cannot be loaded as given. Nothing was written. `lists`
  # names each check that failed and the entry ids it found.
  class Refused < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint load: #{lists.map { |name, ids| "#{name} #{ids.join(', ')}" }.join('; ')}; nothing loaded")
    end
  end

  # Timekeeping already holds entries, so the load already ran: a resumed
  # handoff goes on to reconcile (§10.5 step 6). Nothing was written.
  class AlreadyLoaded < StandardError; end

  Loaded = Data.define(:entries, :reservations)

  # What makes a checkpoint unloadable, each answering the entry ids it
  # finds. `reservations` are TimekeepingReservations::Reservation values.
  CHECKS = {
    not_a_contract_entry: ->(entries, _reservations) {
      entries.reject { |entry| Contracts.errors(:common, "#/$defs/entry", entry).empty? }.pluck("id")
    },
    # A reservation whose entry, or whose entry's tenant, the checkpoint does
    # not hold (§6.3).
    reservation_without_its_entry: ->(entries, reservations) {
      tenants = entries.to_h { |entry| [entry["id"], entry["company_id"]] }
      reservations.reject { |reservation| tenants[reservation.entry_id] == reservation.company_id }.map(&:entry_id)
    },
    # No pending billing operation crosses the handoff (§10.5 step 2).
    provisional_reservation: ->(_entries, reservations) { reservations.reject { |reservation| reservation.state == :committed }.map(&:entry_id) },
    locked_not_derived: ->(entries, reservations) {
      entries.reject { |entry| entry["locked"] == TimekeepingReservations.locked?(entry["id"], reservations) }.pluck("id")
    }
  }.freeze

  # Loads `entries` (common.json#/$defs/entry each) and `reservations`
  # (TimekeepingReservations::Reservation values), as the checkpoint taken
  # at `generation` holds them. `request_id` is the handoff's, carried on
  # every snapshot (§11.3).
  def self.call(generation:, entries:, reservations:, request_id:)
    Ownership.transaction do
      ensure_frozen_legacy!(Ownership.lock_shared!, generation)
      raise AlreadyLoaded, "Timekeeping checkpoint load: Timekeeping already holds entries; nothing loaded" if Entry.exists?

      ensure_loadable!(entries, reservations)
      write!(entries, reservations, request_id)
      Loaded.new(entries: entries.size, reservations: reservations.size)
    end
  end

  def self.ensure_frozen_legacy!(ownership, generation)
    TimekeepingReservations::Handoff.ensure_in_step!(:load, STATES, ownership, generation)
    return if ownership.owner_legacy?

    raise OutOfStep, "Timekeeping handoff: the checkpoint load expects owner legacy, found #{ownership.summary}; nothing loaded"
  end
  private_class_method :ensure_frozen_legacy!

  def self.ensure_loadable!(entries, reservations)
    lists = CHECKS.transform_values { |check| check.call(entries, reservations).uniq }.reject { |_, ids| ids.empty? }
    raise Refused, lists if lists.any?
  end
  private_class_method :ensure_loadable!

  def self.write!(entries, reservations, request_id)
    return if entries.empty?

    Entry.insert_all!(entries.map { |entry| entry.except("locked") }, record_timestamps: false)
    Reservation.insert_all!(reservations.map { |reservation| Reservation.row_for(reservation) }) if reservations.any?
    OutboxSnapshot.insert_all!(snapshots(entries.map { |entry| entry.fetch("id") }, request_id))
    advance_sequence!(entries.map { |entry| entry.fetch("id") }.max)
  end
  private_class_method :write!

  def self.snapshots(ids, request_id)
    Entry.where(id: ids).includes(:reservations).order(:id).map do |entry|
      { entry_id: entry.id, company_id: entry.company_id, version: entry.version, snapshot: OutboxSnapshot.of(entry), request_id: }
    end
  end
  private_class_method :snapshots

  # §10.3: set above the highest copied id. A sequence only advances, so one
  # already past it stays where it is.
  def self.advance_sequence!(highest)
    connection = Entry.connection
    connection.select_value(<<~SQL.squish)
      SELECT setval(#{connection.quote(Entry.sequence_name)}, GREATEST(#{Integer(highest)}, last_value))
      FROM #{connection.quote_table_name(Entry.sequence_name)}
    SQL
  end
  private_class_method :advance_sequence!
end
