# frozen_string_literal: true

# Step 6 of the re-cutover on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4
# "Reconciliation"), monolith -> timekeeping: the checkpoint
# Timekeeping::LocalCheckpoint took out of the prepared application, compared
# with this application's own tables. Timekeeping reconciles what its
# re-cutover load left against the same checkpoint
# (services/timekeeping/app/services/recutover_reconcile.rb, reached through
# Timekeeping::HandoffClient#reconcile_recutover_checkpoint); the handoff tool
# carries the checkpoint to both, as the two applications share no database
# (§11.2).
#
# At a re-cutover this application is the outgoing owner, the source the
# checkpoint was taken from, as well as the holder of the projection and the
# invoices. So this side covers every row of §10.4's table whose source or
# target is here, each exact, through the rollback's checks
# (Timekeeping::RollbackReconcile.differences), which read the same tables:
#
# - Entries, reservations and receipts: the prepared application's entries
#   (every column by id, `version` and the derived `locked` included), each
#   entry's reservations (owner, tenant, state, edit_lock, disposition, the
#   retained ones of destroyed invoices included, §7.3), the audit rows by id,
#   the terminal operation receipts by (invoice_id, operation_id) and the
#   idempotency receipts by (company_id, key) are still what the checkpoint
#   carries, so nothing the source holds is left behind (§13 item 3).
# - Reservations vs invoices: every (entry, invoice, tenant) a kept invoice
#   references through a direct or a grouped line is one active reservation
#   the checkpoint carries, and every active reservation is such a reference.
# - Projection: timesheet_entries holds exactly the checkpoint's entries.
#   Freeze drained the prepared application's outbox into it
#   (Timekeeping::LocalRelay, §10.5 step 3) before the take, and Timekeeping's
#   re-cutover load writes no snapshot, so this is "entries through the final
#   outbox position".
# - Money: the financial snapshot (Timekeeping::FinancialSnapshot) the handoff
#   tool took once close had drained every admitted billing write is
#   identical to one taken now.
#
# It runs only while this application's copy of the ownership record is
# frozen under the `monolith` owner at the checkpoint's generation, and holds
# the record FOR SHARE while it reads, so the fence cannot flip or abort the
# handoff under it. Frozen, admission refuses every write here (§10.1) apart
# from the projection consumer's.
#
# It writes nothing and explains nothing away: any difference raises Differs
# (Timekeeping::CheckpointReconcile's, so one rescue serves every direction),
# and the handoff tool aborts the handoff (§10.5 step 6).
module Timekeeping::RecutoverReconcile
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep
  Differs = Timekeeping::CheckpointReconcile::Differs

  # The outgoing owner whose checkpoint this reconciles (§10.2 step 6).
  OUTGOING_OWNER = Timekeeping::LocalCheckpoint::OUTGOING_OWNER

  Reconciled = Data.define(:entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts)

  # Reconciles `checkpoint`, a Timekeeping::LocalCheckpoint::Checkpoint or
  # anything with its members, as the handoff tool carried it to Timekeeping,
  # and `financial_snapshot`, the Timekeeping::FinancialSnapshot the handoff
  # tool took once close had drained every billing write already admitted.
  def self.call(checkpoint, financial_snapshot:)
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen!(:reconcile, checkpoint.generation, owner: OUTGOING_OWNER)

      lists = Timekeeping::RollbackReconcile.differences(checkpoint, financial_snapshot)
      raise Differs, lists if lists.any?

      Reconciled.new(**Reconciled.members.index_with { |part| checkpoint.public_send(part).size })
    end
  end
end
