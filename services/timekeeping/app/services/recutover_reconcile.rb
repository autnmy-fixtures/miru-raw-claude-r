# frozen_string_literal: true

# Step 6 of the re-cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4
# "Reconciliation"): what Timekeeping, the incoming owner, holds once
# RecutoverLoad has loaded the checkpoint taken out of the prepared
# application (Timekeeping::LocalCheckpoint there), compared with that same
# checkpoint. The handoff tool carries it to both steps; the two applications
# share no database (§11.2).
#
# It covers the rows of §10.4's table whose target is the incoming owner, each
# exact:
#
# - Entries: every column of every entry, by id, `version` and the derived
#   `locked` included;
# - Reservations: each entry's owner (invoice and tenant), state, edit_lock
#   and disposition, the retained ones of destroyed invoices included (§7.3);
# - Receipts: the audit rows by id, the terminal operation receipts by
#   `invoice_id/operation_id` and the entry API's idempotency receipts by
#   `company_id/key`, column for column.
#
# Unlike the first cutover's reconcile, the re-cutover's checkpoint carries
# every receipt (the prepared application keeps them as Timekeeping does), so
# each part is compared both ways: missing, unexpected and differing rows.
#
# The rows that read the existing application's tables (reservations against
# kept invoices, the projection, money) are reconciled there, against the
# same checkpoint.
#
# It runs only while Timekeeping's copy of the ownership record is frozen
# under the `monolith` owner at the checkpoint's generation, and holds the
# record FOR SHARE while it reads, so the fence cannot flip or abort the
# handoff under it. Frozen, admission refuses every mutating call
# (Ownership.admit!), so what it reads is what the flip hands over. It reads
# Timekeeping's tables through CheckpointTake.held, the rendering the load
# compares against and a later rollback's take answers.
#
# It writes nothing and explains nothing away: any difference raises
# CheckpointReconcile::Differs, so the handoff API answers it as the first
# cutover's (`checkpoint-differs`), and the handoff tool aborts the handoff.
module RecutoverReconcile
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep
  Differs = CheckpointReconcile::Differs

  Reconciled = Data.define(:entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts)

  JOINED = ->(*columns) { ->(row) { row.values_at(*columns).join("/") } }

  # By the name Differs lists it under: the checkpoint member it reconciles,
  # and what identifies a row: an entry's or audit row's id,
  # `invoice_id/operation_id` or `company_id/key`.
  PARTS = {
    entry: [:entries, ->(row) { row.fetch("id") }],
    entry_audit: [:entry_audits, ->(row) { row.fetch("id") }],
    reservation_operation: [:reservation_operations, JOINED.call("invoice_id", "operation_id")],
    idempotency_receipt: [:idempotency_receipts, JOINED.call("company_id", "key")]
  }.freeze

  # Reconciles `checkpoint`, anything with `generation`, `entries`,
  # `reservations`, `entry_audits`, `reservation_operations` and
  # `idempotency_receipts` in the forms CheckpointTake::Checkpoint holds them
  # (handoff_api.json#/$defs/taken_checkpoint), as RecutoverLoad was given it.
  def self.call(checkpoint)
    Ownership.transaction do
      Ownership.lock_frozen!(:reconcile, checkpoint.generation, owner: RecutoverLoad::OUTGOING_OWNER)

      lists = differences(checkpoint, CheckpointTake.held)
      raise Differs, lists if lists.any?

      Reconciled.new(**Reconciled.members.index_with { |part| checkpoint.public_send(part).size })
    end
  end

  def self.differences(checkpoint, held)
    lists = PARTS.each_with_object({}) do |(name, (member, identify)), found|
      found.merge!(by_identity(name, checkpoint.public_send(member), held.fetch(member), &identify))
    end
    lists[:reservations_differ] = reservations_differ(checkpoint.reservations, held.fetch(:reservations))

    lists.transform_values { |found| found.uniq.sort }.reject { |_, found| found.empty? }
  end
  private_class_method :differences

  # `name`_missing, carried and not held; `name`_unexpected, held and not
  # carried; `name`_differs, held with another value in any column. Rows are
  # identified by the block.
  def self.by_identity(name, carried, held, &identify)
    carried = carried.index_by(&identify)
    held = held.index_by(&identify)

    {
      "#{name}_missing": carried.keys - held.keys,
      "#{name}_unexpected": held.keys - carried.keys,
      "#{name}_differs": carried.filter_map { |key, row| key if held.key?(key) && !same?(row, held[key]) }
    }
  end
  private_class_method :by_identity

  # Equal compared from both sides. Active Support coerces a String into a
  # time when a Time is compared with it, but not the other way round, so a
  # value on either side that is not in contract form (a Time where the
  # contract carries a string) differs instead of being coerced equal.
  def self.same?(carried, held) = carried == held && held == carried
  private_class_method :same?

  # Entry ids whose reservations, as a set, are not the checkpoint's.
  def self.reservations_differ(carried, held)
    carried = carried.group_by(&:entry_id).transform_values(&:to_set)
    held = held.group_by(&:entry_id).transform_values(&:to_set)

    (carried.keys | held.keys).reject { |entry_id| carried[entry_id] == held[entry_id] }
  end
  private_class_method :reservations_differ
end
