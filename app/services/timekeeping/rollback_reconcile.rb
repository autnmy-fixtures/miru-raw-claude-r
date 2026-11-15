# frozen_string_literal: true

# Step 6 of the rollback on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4
# "Reconciliation"): the checkpoint taken out of Timekeeping, the outgoing
# owner (Timekeeping::HandoffClient#take_checkpoint), compared with this
# application's own tables once Timekeeping::CheckpointLoad has loaded it
# into the prepared application. The handoff tool carries the checkpoint
# across; the two applications share no database (§11.2).
#
# At a rollback this application is the incoming owner as well as the holder
# of the projection and the invoices, so every row of §10.4's table is read
# here, each exact:
#
# - Entries: the prepared application's entries (timekeeping_entries), every
#   column of every entry by id, `version` and the derived `locked` included,
#   are the checkpoint's entries.
# - Reservations: each entry's reservations in timekeeping_reservations
#   (owner, tenant, state, edit_lock, disposition) are the checkpoint's, the
#   retained ones of destroyed invoices included (§7.3).
# - Receipts: the audit rows by id, the terminal operation receipts by
#   (invoice_id, operation_id) and the entry API's idempotency receipts by
#   (company_id, key) are the checkpoint's, column for column.
# - Reservations vs invoices, projection and money: the same checks as the
#   first cutover's (Timekeeping::CheckpointReconcile.differences). Kept
#   invoices' direct and grouped lines are the checkpoint's active
#   reservations; timesheet_entries holds the checkpoint's entries, which
#   freeze drained Timekeeping's outbox into (§10.5 step 3), so this is
#   "Timekeeping entries through the final outbox position"; and the financial
#   snapshot taken once close had drained every admitted billing write is
#   identical to one taken now.
#
# It runs only while this application's copy of the ownership record is
# frozen under the `timekeeping` owner at the checkpoint's generation, and
# holds the record FOR SHARE while it reads, so the fence cannot flip or abort
# the handoff under it. Frozen, admission refuses every write here (§10.1)
# apart from the projection consumer's.
#
# It writes nothing and explains nothing away: any difference raises Differs
# (Timekeeping::CheckpointReconcile's, so one rescue serves both directions),
# and the handoff tool aborts the handoff (§10.5 step 6).
module Timekeeping::RollbackReconcile
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep
  Differs = Timekeeping::CheckpointReconcile::Differs

  Reconciled = Data.define(:entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts)

  JOINED = ->(*columns) { ->(row) { row.values_at(*columns).join("/") } }

  # By the name Differs lists it under: the checkpoint member it reconciles
  # (Timekeeping::PreparedRows::PARTS), and what identifies a row: the audit
  # row's id, `invoice_id/operation_id` or `company_id/key`.
  PARTS = {
    entry_audit: [:entry_audits, ->(row) { row.fetch("id") }],
    reservation_operation: [:reservation_operations, JOINED.call("invoice_id", "operation_id")],
    idempotency_receipt: [:idempotency_receipts, JOINED.call("company_id", "key")]
  }.freeze

  # Reconciles `checkpoint`, anything with the members of
  # Timekeeping::HandoffClient::TakenCheckpoint, as Timekeeping::CheckpointLoad
  # was given it, and `financial_snapshot`, the Timekeeping::FinancialSnapshot
  # the handoff tool took once close had drained every billing write already
  # admitted.
  def self.call(checkpoint, financial_snapshot:)
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen!(:reconcile, checkpoint.generation, owner: Timekeeping::CheckpointLoad::OUTGOING_OWNER)

      lists = differences(checkpoint, financial_snapshot)
      raise Differs, lists if lists.any?

      Reconciled.new(**Reconciled.members.index_with { |part| checkpoint.public_send(part).size })
    end
  end

  def self.differences(checkpoint, financial_snapshot)
    lists = incoming_owner_lists(checkpoint).merge(
      Timekeeping::CheckpointReconcile.differences(
        entries: checkpoint.entries, reservations: checkpoint.reservations, financial_snapshot:
      )
    )
    lists.transform_values { |found| found.uniq.sort }.reject { |_, found| found.empty? }
  end
  private_class_method :differences

  # What the prepared application holds against what the checkpoint carries.
  def self.incoming_owner_lists(checkpoint)
    lists = by_identity(:entry, checkpoint.entries, Timekeeping::PreparedRows.entries) { |entry| entry.fetch("id") }
    lists[:reservations_differ] = reservations_differ(checkpoint.reservations)

    PARTS.each do |name, (member, identify)|
      lists.merge!(by_identity(name, checkpoint.public_send(member), Timekeeping::PreparedRows.held(member), &identify))
    end
    lists
  end
  private_class_method :incoming_owner_lists

  # `name`_missing, carried and not held; `name`_unexpected, held and not
  # carried; `name`_differs, held with another value in any column. Rows are
  # identified by the block. The carried row is compared first: its values
  # are JSON's, so a held value that is not in contract form (a Time where
  # the contract carries a string) differs instead of being coerced equal.
  def self.by_identity(name, carried, held, &identify)
    carried = carried.index_by(&identify)
    held = held.index_by(&identify)

    {
      "#{name}_missing": carried.keys - held.keys,
      "#{name}_unexpected": held.keys - carried.keys,
      "#{name}_differs": carried.filter_map { |key, row| key if held.key?(key) && row != held[key] }
    }
  end
  private_class_method :by_identity

  # Entry ids whose reservations, as a set, are not the checkpoint's.
  def self.reservations_differ(carried)
    carried = carried.group_by(&:entry_id).transform_values(&:to_set)
    held = Timekeeping::PreparedRows.reservations.group_by(&:entry_id).transform_values(&:to_set)

    (carried.keys | held.keys).reject { |entry_id| carried[entry_id] == held[entry_id] }
  end
  private_class_method :reservations_differ
end
