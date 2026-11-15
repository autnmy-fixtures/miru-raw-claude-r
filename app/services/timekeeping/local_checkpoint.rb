# frozen_string_literal: true

# Step 4 of the re-cutover on this application's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 4): the
# frozen checkpoint taken from the prepared application, the `monolith`
# owner, as the outgoing owner, for the handoff tool to load into Timekeeping
# and reconcile there. The two applications share no database (§11.2), so the
# tool carries it across. It is the rollback's take (CheckpointTake in
# Timekeeping) in the other direction, and carries the same parts in the same
# forms (handoff_api.json#/$defs/taken_checkpoint), so either owner's load
# reads one shape:
#
# - every entry of timekeeping_entries, discarded ones included, as the full
#   entry (common.json#/$defs/entry), at the version the prepared application
#   holds and with the `locked` its reservations derive (§7.1). The handoff
#   drains the prepared application's outbox into the projection before the
#   take (§10.5 step 3, Timekeeping::LocalRelay), so timesheet_entries
#   already holds these versions and nothing is renumbered;
# - each entry's reservations, as TimekeepingReservations::Reservation values,
#   the retained ones of destroyed invoices with their own owner data (§7.3);
# - the entry audit rows, with their ids;
# - every terminal invoice-operation receipt, committed or aborted (§5.3),
#   those Timekeeping resolved before the rollback included, since the
#   rollback's load carried them here;
# - the entry API's idempotency receipts, so a client retry after the
#   re-cutover returns its stored result (§5.2, §9.4).
#
# Every value is in the form JSON carries unchanged (§5.1, §8 item 1), as
# Timekeeping::PreparedRows reads it. Nothing is recomputed.
#
# It runs only while this application's copy of the ownership record is
# frozen under the `monolith` owner at the handoff's generation, and holds the
# record FOR SHARE while it reads, so the fence cannot flip or abort the
# handoff under it. Frozen, admission refuses every write here (§10.1), and
# freeze was refused while the invoice operation ledger held an unsettled
# intent (Timekeeping::HandoffFence), so what it reads is the state the flip
# hands over.
#
# No pending billing operation crosses the handoff (§10.5 step 2): the
# carried tables are checked again, and a provisional reservation or an
# operation still prepared means settle did not finish there, so nothing is
# taken (Unsettled). It writes nothing.
module Timekeeping::LocalCheckpoint
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # The outgoing owner whose tables this takes (§10.2 step 6).
  OUTGOING_OWNER = "monolith"

  # Settle did not resolve every operation (§10.5 step 2). Nothing was taken.
  # `lists` names each check that failed and what it found: entry ids for a
  # provisional reservation, `invoice_id/operation_id` for an operation still
  # prepared.
  class Unsettled < StandardError
    attr_reader :lists

    def initialize(lists)
      @lists = lists
      super("Timekeeping checkpoint: #{lists.map { |name, found| "#{name} #{found.join(', ')}" }.join('; ')}; settle first, nothing taken")
    end
  end

  Checkpoint = Data.define(:generation, :entries, :reservations, :entry_audits, :reservation_operations, :idempotency_receipts) do
    # The id the incoming owner's entry sequence is set above (§10.3); nil
    # when there is no entry.
    def highest_entry_id = entries.map { |entry| entry.fetch("id") }.max

    # Audit rows keep their ids, so the incoming owner's audit sequence is set
    # above this too; nil when there is no audit row.
    def highest_entry_audit_id = entry_audits.map { |audit| audit.fetch("id") }.max
  end

  # What stops the checkpoint: anything settle should have resolved.
  CHECKS = {
    provisional_reservation: -> {
      Timekeeping::Reservation.where(state: "provisional").distinct.order(:entry_id).pluck(:entry_id)
    },
    unresolved_operation: -> {
      Timekeeping::ReservationOperation.state_prepared.order(:invoice_id, :operation_id)
        .pluck(:invoice_id, :operation_id).map { |pair| pair.join("/") }
    }
  }.freeze

  def self.take(generation:)
    Timekeeping::Ownership.transaction do
      Timekeeping::Ownership.lock_frozen!(:checkpoint, generation, owner: OUTGOING_OWNER)
      ensure_settled!

      Checkpoint.new(
        generation:,
        entries: Timekeeping::PreparedRows.entries,
        reservations: Timekeeping::PreparedRows.reservations,
        **Timekeeping::PreparedRows::PARTS.keys.index_with { |member| Timekeeping::PreparedRows.held(member) }
      )
    end
  end

  def self.ensure_settled!
    lists = CHECKS.transform_values(&:call).reject { |_, found| found.empty? }
    raise Unsettled, lists if lists.any?
  end
  private_class_method :ensure_settled!
end
