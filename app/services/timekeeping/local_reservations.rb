# frozen_string_literal: true

# The prepared application's reservation provider
# (docs/architecture/timekeeping-soa.md §10.2 step 4, §10.5): prepare, commit
# and abort of §5.3, run in-process against the local reservation table and
# decided by the shared decision table (§7.2), which nobody re-implements.
# It is inactive: the gateway routes no owner to it until the `monolith`
# owner is built.
#
# It keeps the protocol Timekeeping keeps: idempotency and a terminal receipt
# per (invoice, operation), at most one unresolved operation per invoice
# (`resolves`), and an abort of an operation never prepared as a no-op that
# still leaves a receipt (§9.3). It checks no generation: it runs in-process,
# inside the gateway's own admitted transaction (§10.1).
#
# `entries` is the authoritative entry store of the owner it serves. Its
# `lock(ids)` takes the entry rows SELECT ... FOR UPDATE in id order (§9.4),
# so reservation changes serialize with entry edits and with each other, and
# answers { id => TimekeepingReservations::Entry } for the ids that exist.
# The unique indexes of the table are the backstop, not the lock.
class Timekeeping::LocalReservations
  Rule = TimekeepingReservations

  # 200 prepared: the entries of the desired set, authoritative for
  # existence and company (L8).
  Prepared = Data.define(:entries)
  # 200 with the stored terminal receipt: nothing changed.
  Receipt = Data.define(:status)
  # 409 operation-unresolved, retryable: an earlier operation of the invoice
  # is not terminal and `resolves` did not carry its outcome.
  Unresolved = Data.define(:operation_id)
  # 404 not-found: a commit of an operation that was never prepared.
  NotPrepared = Data.define(:operation_id)
  # 409 reservation-refused is the rule's own Rule::Refused.

  # A prepare replayed for an unresolved operation with another body.
  class ProtocolError < StandardError; end

  OUTCOMES = {
    committed: ->(operation, reservations) { Rule.commit(operation, reservations:) },
    aborted: ->(operation, reservations) { Rule.abort(operation, reservations:) }
  }.freeze

  def initialize(entries:)
    @entries = entries
  end

  # `resolves` is nil, or { operation_id:, outcome: } for the invoice's
  # earlier unresolved operation (§5.3).
  def prepare(operation, resolves: nil)
    within_savepoint do
      record = find_record(operation.invoice_id, operation.operation_id)
      next receipt(record) if record&.terminal?
      if record && record.to_operation != operation
        raise ProtocolError, "operation #{operation.operation_id} was prepared with another body"
      end

      earlier = record ? nil : unresolved_before(operation)
      next Unresolved.new(operation_id: earlier.operation_id) if earlier && resolves&.fetch(:operation_id) != earlier.operation_id

      resolve(earlier, resolves.fetch(:outcome)) if earlier
      reserve(operation, record)
    end
  end

  def commit(invoice_id:, operation_id:)
    within_savepoint do
      record = find_record(invoice_id, operation_id)
      next NotPrepared.new(operation_id:) unless record

      record.terminal? ? receipt(record) : resolve(record, :committed)
    end
  end

  def abort(invoice_id:, operation_id:)
    within_savepoint do
      record = find_record(invoice_id, operation_id)
      next receipt(Timekeeping::ReservationOperation.create!(invoice_id:, operation_id:, state: :aborted)) unless record

      record.terminal? ? receipt(record) : resolve(record, :aborted)
    end
  end

  private

    # Joins the caller's transaction as a savepoint, so a failure rolls back
    # only this call's changes.
    def within_savepoint(&)
      Timekeeping::ReservationOperation.transaction(requires_new: true, &)
    end

    def find_record(invoice_id, operation_id)
      Timekeeping::ReservationOperation.lock.find_by(invoice_id:, operation_id:)
    end

    def unresolved_before(operation)
      Timekeeping::ReservationOperation.lock.state_prepared.find_by(invoice_id: operation.invoice_id)
    end

    def receipt(record)
      Receipt.new(status: record.state.to_sym)
    end

    def reserve(operation, record)
      change_reservations(operation) do |entries, reservations|
        result = Rule.prepare(operation, entries:, reservations:)
        next [reservations, result] if result.is_a?(Rule::Refused)

        record || Timekeeping::ReservationOperation.create!(**Timekeeping::ReservationOperation.row_for(operation), state: :prepared)
        [result.reservations, Prepared.new(entries: entries.values_at(*operation.entry_ids).compact)]
      end
    end

    def resolve(record, outcome)
      operation = record.to_operation
      change_reservations(operation) do |_entries, reservations|
        [OUTCOMES.fetch(outcome.to_sym).call(operation, reservations), nil]
      end
      record.update!(state: outcome)
      receipt(record)
    end

    # Locks the entries the operation touches, then their reservations, and
    # yields both. The block answers the reservations after the change and
    # the call's result; only the reservations that changed are written.
    def change_reservations(operation)
      held = Timekeeping::Reservation.where(invoice_id: operation.invoice_id).distinct.pluck(:entry_id)
      entry_ids = (operation.entry_ids | held).sort
      entries = @entries.lock(entry_ids)
      rows = Timekeeping::Reservation.where(entry_id: entry_ids).order(:id).lock.index_by(&:to_value)
      after, result = yield entries, rows.keys
      persist(rows, after)
      result
    end

    # Deletes before inserting, so a reservation that replaces another never
    # meets it in a unique index.
    def persist(rows, after)
      stale = rows.except(*after).values
      fresh = after - rows.keys
      Timekeeping::Reservation.where(id: stale.map(&:id)).delete_all if stale.any?
      Timekeeping::Reservation.insert_all!(fresh.map { |value| Timekeeping::Reservation.row_for(value) }) if fresh.any?
    end
end
