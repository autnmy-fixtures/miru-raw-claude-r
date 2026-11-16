# frozen_string_literal: true

# Step 4 of the rollback on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 4): the
# frozen checkpoint taken from Timekeeping, the outgoing owner, for the
# handoff tool to load into the prepared existing application (the
# `monolith` owner) and reconcile there. The two applications share no
# database (§11.2), so the tool carries it across.
#
# It holds what §10.5 step 4 lists:
#
# - every entry, discarded ones included, as the full entry
#   (common.json#/$defs/entry), at the version Timekeeping holds and with the
#   `locked` its reservations derive (§7.1). The projection already holds
#   these versions (§10.5 step 3 drains the outbox before the checkpoint), so
#   unlike the first cutover's checkpoint nothing is renumbered;
# - each entry's reservations, as TimekeepingReservations::Reservation values:
#   owner (invoice and tenant), state, edit_lock and disposition, including
#   the reservations of destroyed invoices, which carry their own owner (§7.3);
# - the entry audit rows, with their ids;
# - every terminal invoice-operation receipt, committed or aborted (§5.3);
# - the entry API's idempotency receipts, so a client retry after the
#   rollback returns its stored result (§5.2, §9.4).
#
# Every value is in the form JSON carries it unchanged (§5.1, §8 item 1):
# duration stays the stored float, timestamps are UTC to the microsecond,
# and JSON columns are carried as stored. Nothing is recomputed.
#
# It runs only while Timekeeping's copy of the ownership record is frozen
# under owner `timekeeping` at the handoff's generation, and holds the record
# FOR SHARE while it reads, so the fence cannot flip or abort the handoff
# under it. Frozen, admission refuses every mutating call and the settle
# step's exception has ended (Ownership.admit!, #settling?), so what it reads
# is the state the flip hands over.
#
# No pending billing operation crosses the handoff (§10.5 step 2): a
# provisional reservation or an operation still prepared means settle did
# not finish, and nothing is taken (Unsettled). It writes nothing.
module CheckpointTake
  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

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
  end

  # A timestamp as the contracts carry it (§5.1).
  TIMESTAMP = ->(time) { time&.utc&.iso8601(6) }

  # The columns each audit row and receipt carries. A column not listed in
  # FORMATS is carried as stored. Audit rows keep their ids, the
  # only identity they have; a receipt is identified by its own key,
  # (invoice_id, operation_id) or (company_id, key), so its surrogate id stays
  # behind.
  COLUMNS = {
    entry_audits: %w[id entry_id company_id version action actor agent_id writer request_id audited_changes created_at],
    reservation_operations: %w[invoice_id operation_id company_id kind invoice_state entry_ids state created_at updated_at],
    idempotency_receipts: %w[company_id key request_digest status response created_at]
  }.freeze

  FORMATS = { "created_at" => TIMESTAMP, "updated_at" => TIMESTAMP }.freeze

  # What stops the checkpoint: anything settle should have resolved.
  CHECKS = {
    provisional_reservation: -> { Reservation.where(state: "provisional").order(:entry_id).distinct.pluck(:entry_id) },
    unresolved_operation: -> {
      ReservationOperation.state_prepared.order(:invoice_id, :operation_id).pluck(:invoice_id, :operation_id).map { |pair| pair.join("/") }
    }
  }.freeze

  def self.take(generation:)
    Ownership.transaction do
      Ownership.lock_frozen!(:checkpoint, generation, owner: "timekeeping")
      ensure_settled!

      Checkpoint.new(generation:, **held)
    end
  end

  # Every part Timekeeping holds, each in the form a checkpoint carries it and
  # in the order the take answers it. Reads only, with no guard of its own:
  # the caller holds the record as its step needs (the take here, and the
  # re-cutover's load, RecutoverLoad, which compares what it would replace,
  # and its reconcile, RecutoverReconcile, which compares what the load left).
  def self.held
    {
      entries: Entry.includes(:reservations).order(:id).map(&:to_contract),
      reservations: Reservation.order(:entry_id, :id).map(&:to_value),
      entry_audits: rows(:entry_audits, EntryAudit.order(:id)),
      reservation_operations: rows(:reservation_operations, ReservationOperation.order(:invoice_id, :operation_id)),
      idempotency_receipts: rows(:idempotency_receipts, IdempotencyReceipt.order(:company_id, :key))
    }
  end

  def self.ensure_settled!
    lists = CHECKS.transform_values(&:call).reject { |_, found| found.empty? }
    raise Unsettled, lists if lists.any?
  end
  private_class_method :ensure_settled!

  def self.rows(name, scope)
    columns = COLUMNS.fetch(name)
    scope.pluck(*columns).map do |values|
      columns.zip(values).to_h { |column, value| [column, FORMATS.fetch(column, :itself.to_proc).call(value)] }
    end
  end
  private_class_method :rows
end
