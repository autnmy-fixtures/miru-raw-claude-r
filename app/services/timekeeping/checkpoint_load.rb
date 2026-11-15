# frozen_string_literal: true

# Steps 4 and 5 of the rollback on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5): the checkpoint
# taken out of Timekeeping, the outgoing owner (Timekeeping::HandoffClient
# #take_checkpoint, CheckpointTake there), loaded into the prepared
# application's own tables, so the `monolith` owner holds what Timekeeping
# held. Then the entry and audit id sequences are set above the highest
# carried ids (§10.3). The handoff tool carries the checkpoint across; the two
# applications share no database (§11.2).
#
# It loads every part §10.5 step 4 lists, each into the table of the same
# shape:
#
# - entries (common.json#/$defs/entry) into timekeeping_entries, every column
#   as carried, the derived `locked` left to the reservations (§7.1);
# - reservations (TimekeepingReservations::Reservation values) into
#   timekeeping_reservations, the retained ones of destroyed invoices with
#   their own owner data (§7.3);
# - audit rows (handoff_api.json#/$defs/entry_audit) into
#   timekeeping_entry_audits, with their ids, the only identity they have;
# - terminal operation receipts (#/$defs/operation_receipt) into
#   timekeeping_reservation_operations, so a late or replayed prepare,
#   commit or abort of an operation Timekeeping resolved answers its stored
#   receipt here (§5.3, §9.3);
# - the entry API's idempotency receipts (#/$defs/idempotency_receipt) into
#   timekeeping_idempotency_receipts (§9.4).
#
# It runs only while this application's copy of the ownership record is
# frozen under the `timekeeping` owner at the handoff's generation, and holds
# the record FOR SHARE while it writes, so the fence cannot flip or abort the
# handoff under it. Frozen, admission refuses every write here (§10.1), so
# the load is the only writer of these tables.
#
# One transaction: every part and both sequences, or nothing. Values are
# copied as carried (§8 item 1): no writer's rule, callback or audit row
# runs, and created_at and updated_at are kept. No outbox snapshot is
# written: freeze drained Timekeeping's outbox into the projection (§10.5
# step 3), so timesheet_entries already holds every carried entry at its
# carried version, and the next change the `monolith` owner makes writes the
# next version (Timekeeping::LocalEntryChange). The rollback's reconcile
# checks the projection against the checkpoint.
#
# Nothing is normalized (§10.4): a checkpoint that does not hold together is
# refused whole, listing what each check found.
module Timekeeping::CheckpointLoad
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # The outgoing owner whose checkpoint this loads (§10.2 step 6).
  OUTGOING_OWNER = "timekeeping"

  # The checkpoint cannot be loaded as given. Nothing was written. `lists`
  # names each check that failed and what it found: entry ids for entries
  # and reservations, audit ids for audit rows, `invoice_id/operation_id`
  # for operation receipts and `company_id/key` for idempotency receipts.
  class Refused < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint load: #{lists.map { |name, found| "#{name} #{found.join(', ')}" }.join('; ')}; nothing loaded")
    end
  end

  # The prepared application already holds rows the load writes, so the load
  # already ran: a resumed handoff goes on to reconcile (§10.5 step 6).
  # Nothing was written.
  class AlreadyLoaded < StandardError; end

  Loaded = Data.define(:entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts)

  # The tables the load writes. Any row in one means it already ran.
  TABLES = [
    Timekeeping::Entry, Timekeeping::Reservation, Timekeeping::EntryAudit,
    Timekeeping::ReservationOperation, Timekeeping::IdempotencyReceipt
  ].freeze

  # Each carried row the contract does not describe, by what identifies it.
  CONTRACT_ROW = lambda do |document, pointer, identify|
    ->(rows) { rows.reject { |row| Timekeeping::Contracts.errors(document, pointer, row).empty? }.map(&identify) }
  end

  # What makes a checkpoint unloadable, each answering what it finds in
  # `checkpoint`.
  CHECKS = {
    not_a_contract_entry: ->(checkpoint) {
      CONTRACT_ROW.call(:common, "#/$defs/entry", ->(entry) { entry["id"] }).call(checkpoint.entries)
    },
    # A reservation whose entry, or whose entry's tenant, the checkpoint does
    # not hold (§6.3).
    reservation_without_its_entry: ->(checkpoint) {
      tenants = checkpoint.entries.to_h { |entry| [entry["id"], entry["company_id"]] }
      checkpoint.reservations.reject { |reservation| tenants[reservation.entry_id] == reservation.company_id }.map(&:entry_id)
    },
    # No pending billing operation crosses the handoff (§10.5 step 2).
    provisional_reservation: ->(checkpoint) {
      checkpoint.reservations.reject { |reservation| reservation.state == :committed }.map(&:entry_id)
    },
    locked_not_derived: ->(checkpoint) {
      checkpoint.entries.reject { |entry| entry["locked"] == TimekeepingReservations.locked?(entry["id"], checkpoint.reservations) }
        .pluck("id")
    },
    not_a_contract_audit: ->(checkpoint) {
      CONTRACT_ROW.call(:handoff_api, "#/$defs/entry_audit", ->(audit) { audit["id"] }).call(checkpoint.entry_audits)
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
      CONTRACT_ROW.call(:handoff_api, "#/$defs/operation_receipt", ->(receipt) { receipt.values_at("invoice_id", "operation_id").join("/") })
        .call(checkpoint.reservation_operations)
    },
    not_a_contract_idempotency_receipt: ->(checkpoint) {
      CONTRACT_ROW.call(:handoff_api, "#/$defs/idempotency_receipt", ->(receipt) { receipt.values_at("company_id", "key").join("/") })
        .call(checkpoint.idempotency_receipts)
    }
  }.freeze

  # Loads `checkpoint`, anything with `generation`, `entries`,
  # `reservations`, `entry_audits`, `reservation_operations` and
  # `idempotency_receipts` in the forms Timekeeping::HandoffClient::
  # TakenCheckpoint holds them, taken at `generation`.
  def self.call(checkpoint)
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen!(:load, checkpoint.generation, owner: OUTGOING_OWNER)
      ensure_not_loaded!
      ensure_loadable!(checkpoint)
      write!(checkpoint)
      Loaded.new(**Loaded.members.index_with { |part| checkpoint.public_send(part).size })
    end
  end

  def self.ensure_not_loaded!
    holding = TABLES.select(&:exists?)
    return if holding.empty?

    raise AlreadyLoaded,
      "Timekeeping checkpoint load: the prepared application already holds #{holding.map(&:table_name).join(', ')}; nothing loaded"
  end
  private_class_method :ensure_not_loaded!

  def self.ensure_loadable!(checkpoint)
    lists = CHECKS.transform_values { |check| check.call(checkpoint).uniq }.reject { |_, found| found.empty? }
    raise Refused, lists if lists.any?
  end
  private_class_method :ensure_loadable!

  def self.write!(checkpoint)
    insert!(Timekeeping::Entry, checkpoint.entries.map { |entry| Timekeeping::Entry.row_for(entry) }, record_timestamps: false)
    insert!(Timekeeping::Reservation, checkpoint.reservations.map { |reservation| Timekeeping::Reservation.row_for(reservation) })
    insert!(Timekeeping::EntryAudit, checkpoint.entry_audits, record_timestamps: false)
    insert!(Timekeeping::ReservationOperation, checkpoint.reservation_operations, record_timestamps: false)
    insert!(Timekeeping::IdempotencyReceipt, checkpoint.idempotency_receipts, record_timestamps: false)
    advance_sequence!(Timekeeping::Entry, checkpoint.entries)
    advance_sequence!(Timekeeping::EntryAudit, checkpoint.entry_audits)
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
