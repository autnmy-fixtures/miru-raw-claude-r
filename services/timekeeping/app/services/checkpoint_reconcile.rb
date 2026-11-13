# frozen_string_literal: true

# Step 6 of the first cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.5, §10.4 "Reconciliation"): what
# Timekeeping, the incoming owner, holds after CheckpointLoad, compared with
# the checkpoint the existing application took from the legacy owner
# (Timekeeping::LegacyCheckpoint there). The handoff tool carries the same
# checkpoint to both steps; the two applications share no database (§11.2).
#
# It covers the rows of §10.4's table whose target is the incoming owner, each
# exact:
#
# - Entries: every column of every entry, by id, `version` and the derived
#   `locked` included;
# - Reservations: each entry's owner (invoice and tenant), state, edit_lock
#   and disposition;
# - Receipts: the legacy owner keeps no invoice-operation receipt and no entry
#   API idempotency receipt, so the first cutover's checkpoint carries none
#   and Timekeeping must hold none.
#
# The rows that read the existing application's tables (reservations against
# kept invoices, the projection, money) are reconciled there, by
# Timekeeping::CheckpointReconcile against the same checkpoint.
#
# It runs only while Timekeeping's copy of the ownership record is frozen
# under the legacy owner at the handoff's generation, and holds the record
# FOR SHARE while it reads, so the handoff cannot flip or abort under it.
# Frozen, nothing else writes here (Ownership.admit!), so what it reads is
# what the flip hands over.
#
# It writes nothing and explains nothing away: any difference raises Differs,
# and the handoff tool aborts the handoff (§10.5 step 6).
module CheckpointReconcile
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # Timekeeping does not hold what the checkpoint carries. `lists` names each
  # check that failed and what it found: entry ids for entries and
  # reservations, `invoice_id/operation_id` for a reservation operation (a
  # terminal receipt, or one still prepared) and `company_id/key` for an
  # idempotency receipt.
  class Differs < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint reconcile: #{lists.map { |name, found| "#{name} #{found.join(', ')}" }.join('; ')}; abort the handoff")
    end
  end

  Reconciled = Data.define(:entries, :reservations)

  # One side of the comparison. `entries` are common.json#/$defs/entry each,
  # by id; `reservations` are TimekeepingReservations::Reservation sets, by
  # entry id; the receipts are the identifiers Differs lists.
  State = Data.define(:entries, :reservations, :reservation_operations, :idempotency_receipts) do
    def self.of(entries:, reservations:, reservation_operations: [], idempotency_receipts: [])
      new(
        entries: entries.index_by { |entry| entry.fetch("id") },
        reservations: reservations.group_by(&:entry_id).transform_values(&:to_set),
        reservation_operations:, idempotency_receipts:
      )
    end
  end

  # Each check answers what differs between the `carried` checkpoint and the
  # `held` state, empty when they agree.
  CHECKS = {
    entry_missing: ->(carried, held) { carried.entries.keys - held.entries.keys },
    entry_unexpected: ->(carried, held) { held.entries.keys - carried.entries.keys },
    entry_differs: ->(carried, held) {
      carried.entries.filter_map { |id, entry| id if held.entries.key?(id) && held.entries[id] != entry }
    },
    reservations_differ: ->(carried, held) {
      (carried.reservations.keys | held.reservations.keys)
        .reject { |entry_id| carried.reservations[entry_id] == held.reservations[entry_id] }
    },
    reservation_operation_unexpected: ->(carried, held) { held.reservation_operations - carried.reservation_operations },
    idempotency_receipt_unexpected: ->(carried, held) { held.idempotency_receipts - carried.idempotency_receipts }
  }.freeze

  # Reconciles against `entries` (common.json#/$defs/entry each) and
  # `reservations` (TimekeepingReservations::Reservation values), the
  # checkpoint taken at `generation` as CheckpointLoad was given it.
  def self.call(generation:, entries:, reservations:)
    Ownership.transaction do
      Ownership.lock_frozen_legacy!(:reconcile, generation)

      ensure_agrees!(State.of(entries:, reservations:), held)
      Reconciled.new(entries: entries.size, reservations: reservations.size)
    end
  end

  def self.held
    State.of(
      entries: Entry.includes(:reservations).order(:id).map(&:to_contract),
      reservations: Reservation.order(:entry_id, :id).map(&:to_value),
      reservation_operations: ReservationOperation.order(:id).pluck(:invoice_id, :operation_id).map { |pair| pair.join("/") },
      idempotency_receipts: IdempotencyReceipt.order(:id).pluck(:company_id, :key).map { |pair| pair.join("/") }
    )
  end
  private_class_method :held

  def self.ensure_agrees!(carried, held)
    lists = CHECKS.transform_values { |check| check.call(carried, held).sort }.reject { |_, found| found.empty? }
    raise Differs, lists if lists.any?
  end
  private_class_method :ensure_agrees!
end
