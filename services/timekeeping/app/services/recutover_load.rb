# frozen_string_literal: true

# Steps 4 and 5 of the re-cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5): the checkpoint
# the existing application took out of the prepared application, the
# outgoing `monolith` owner (Timekeeping::LocalCheckpoint there), loaded into
# Timekeeping, the incoming owner. Then the entry and audit id sequences are
# set above the highest carried ids (§10.3). The handoff tool carries the
# checkpoint across; the two applications share no database (§11.2).
#
# Unlike the first cutover's CheckpointLoad, Timekeeping is not empty here.
# It still holds what it held when the rollback took its checkpoint, and the
# prepared application loaded all of that and went on writing. So the
# checkpoint replaces Timekeeping's tables:
#
# - entries (common.json#/$defs/entry) are written over by id, every column
#   as carried, the derived `locked` left to the reservations (§7.1);
# - reservations, audit rows (with their ids), terminal operation receipts
#   and idempotency receipts are replaced by the checkpoint's.
#
# Before it writes, it refuses a checkpoint that would drop what Timekeeping
# holds (§13 item 3: rollback and re-cutover keep every write accepted on
# either side). An entry must be carried at the version held or a later one,
# and the same content at the same version. An audit row, a terminal receipt
# and an idempotency receipt never change once written, so each one held
# must be carried as it is held. Reservations are not compared: they are the
# outgoing owner's, the shared rule moved them there after the rollback, and
# the checkpoint is their state.
#
# It runs only while Timekeeping's copy of the ownership record is frozen
# under the `monolith` owner at the handoff's generation, and holds the
# record FOR SHARE while it reads and writes, so the fence cannot flip or
# abort the handoff under it. Frozen, admission refuses every mutating call
# (Ownership.admit!), so the load is the only writer.
#
# One transaction: every part and both sequences, or nothing. Values are
# copied as carried (§8 item 1): no writer's rule, callback or audit row
# runs, and created_at and updated_at are kept. No outbox snapshot is
# written: freeze drained the prepared application's outbox into the
# projection (§10.5 step 3), so timesheet_entries already holds every carried
# entry at its carried version, and Timekeeping's next change writes the next
# one. The outbox keeps its rows: they are delivered, and none can collide
# with a later version.
#
# Loading the same checkpoint again leaves the same tables, so a resumed
# handoff can run it again and go on to reconcile; there is no AlreadyLoaded.
#
# Nothing is normalized (§10.4): a checkpoint that does not hold together, or
# that would drop what Timekeeping holds, is refused whole, listing what each
# check found.
module RecutoverLoad
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # The same refusal as the first cutover's load, so the handoff API answers
  # both as `checkpoint-refused`. Nothing was written. `lists` names each
  # check that failed and what it found: entry ids for entries and
  # reservations, audit ids for audit rows, `invoice_id/operation_id` for
  # operation receipts and `company_id/key` for idempotency receipts.
  Refused = CheckpointLoad::Refused

  # The outgoing owner whose checkpoint this loads (§10.2 step 6).
  OUTGOING_OWNER = "monolith"

  Loaded = Data.define(:entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts)

  # Each carried row the contract does not describe, by what identifies it.
  CONTRACT_ROW = lambda do |pointer, identify|
    ->(rows) { rows.reject { |row| Contracts.errors(:handoff_api, pointer, row).empty? }.map(&identify) }
  end

  # What identifies a row of each part that never changes once written.
  IDENTITIES = {
    entry_audits: ->(audit) { audit["id"] },
    reservation_operations: ->(receipt) { receipt.values_at("invoice_id", "operation_id").join("/") },
    idempotency_receipts: ->(receipt) { receipt.values_at("company_id", "key").join("/") }
  }.freeze

  # What makes a checkpoint unloadable on its own, each answering what it
  # finds in `checkpoint`. The entry and reservation checks are the first
  # cutover's.
  CHECKS = CheckpointLoad::CHECKS.transform_values do |check|
    ->(checkpoint) { check.call(checkpoint.entries, checkpoint.reservations) }
  end.merge(
    not_a_contract_audit: ->(checkpoint) {
      CONTRACT_ROW.call("#/$defs/entry_audit", IDENTITIES.fetch(:entry_audits)).call(checkpoint.entry_audits)
    },
    # An audit row whose entry, or whose entry's tenant, the checkpoint does
    # not hold (§6.3).
    audit_without_its_entry: ->(checkpoint) {
      tenants = checkpoint.entries.to_h { |entry| [entry["id"], entry["company_id"]] }
      checkpoint.entry_audits.reject { |audit| tenants[audit["entry_id"]] == audit["company_id"] }.pluck("id")
    },
    # Only terminal receipts cross the handoff (§10.5 step 2): an operation
    # still prepared is not one.
    not_a_terminal_receipt: ->(checkpoint) {
      CONTRACT_ROW.call("#/$defs/operation_receipt", IDENTITIES.fetch(:reservation_operations)).call(checkpoint.reservation_operations)
    },
    not_a_contract_idempotency_receipt: ->(checkpoint) {
      CONTRACT_ROW.call("#/$defs/idempotency_receipt", IDENTITIES.fetch(:idempotency_receipts)).call(checkpoint.idempotency_receipts)
    }
  ).freeze

  # What the checkpoint would drop of what Timekeeping holds, each answering
  # what it finds given the checkpoint and `held` (CheckpointTake.held, the
  # same rendering).
  DROPS = {
    # Not carried, carried at an older version, or carried at the version
    # held with other content.
    dropped_entry: ->(checkpoint, held) {
      carried = checkpoint.entries.index_by { |entry| entry["id"] }
      held.fetch(:entries).select do |entry|
        version = carried.dig(entry.fetch("id"), "version")
        version.nil? || version < entry.fetch("version") || (version == entry.fetch("version") && carried.fetch(entry.fetch("id")) != entry)
      end.pluck("id")
    }
  }.merge(
    IDENTITIES.to_h do |part, identify|
      [:"dropped_#{part.to_s.singularize}", ->(checkpoint, held) {
        carried = checkpoint.public_send(part).index_by(&identify)
        held.fetch(part).reject { |row| carried[identify.call(row)] == row }.map(&identify)
      }]
    end
  ).freeze

  # The tables the load replaces, in an order their foreign keys to entries
  # allow. Entries themselves are written over, never deleted: the outbox
  # refers to them.
  REPLACED = [Reservation, EntryAudit, ReservationOperation, IdempotencyReceipt].freeze

  # Loads `checkpoint`, anything with `generation`, `entries`,
  # `reservations`, `entry_audits`, `reservation_operations` and
  # `idempotency_receipts` in the forms CheckpointTake::Checkpoint holds
  # them (handoff_api.json#/$defs/taken_checkpoint), taken at `generation`.
  def self.call(checkpoint)
    Ownership.transaction do
      Ownership.lock_frozen!(:load, checkpoint.generation, owner: OUTGOING_OWNER)
      ensure_loadable!(checkpoint)
      write!(checkpoint)
      Loaded.new(**Loaded.members.index_with { |part| checkpoint.public_send(part).size })
    end
  end

  def self.ensure_loadable!(checkpoint)
    held = CheckpointTake.held
    lists = CHECKS.transform_values { |check| check.call(checkpoint) }
      .merge(DROPS.transform_values { |check| check.call(checkpoint, held) })
      .transform_values(&:uniq).reject { |_, found| found.empty? }
    raise Refused, lists if lists.any?
  end
  private_class_method :ensure_loadable!

  def self.write!(checkpoint)
    REPLACED.each(&:delete_all)
    if checkpoint.entries.any?
      Entry.upsert_all(checkpoint.entries.map { |entry| entry.except("locked") }, unique_by: :id, record_timestamps: false)
    end
    insert!(Reservation, checkpoint.reservations.map { |reservation| Reservation.row_for(reservation) })
    insert!(EntryAudit, checkpoint.entry_audits, record_timestamps: false)
    insert!(ReservationOperation, checkpoint.reservation_operations, record_timestamps: false)
    insert!(IdempotencyReceipt, checkpoint.idempotency_receipts, record_timestamps: false)
    advance_sequence!(Entry, checkpoint.entries)
    advance_sequence!(EntryAudit, checkpoint.entry_audits)
  end
  private_class_method :write!

  def self.insert!(model, rows, **options)
    model.insert_all!(rows, **options) if rows.any?
  end
  private_class_method :insert!

  # §10.3: set above the highest carried id. A sequence only advances, so one
  # already past it stays where it is.
  def self.advance_sequence!(model, rows)
    highest = rows.map { |row| row.fetch("id") }.max
    return unless highest

    connection = model.connection
    connection.select_value(<<~SQL.squish)
      SELECT setval(#{connection.quote(model.sequence_name)}, GREATEST(#{Integer(highest)}, last_value))
      FROM #{connection.quote_table_name(model.sequence_name)}
    SQL
  end
  private_class_method :advance_sequence!
end
