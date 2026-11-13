# frozen_string_literal: true

# The reservation API's provider (docs/architecture/timekeeping-soa.md §5.3,
# §7, §9): prepare, commit and abort of one invoice operation, decided by the
# shared decision table (§7.2), which nobody re-implements. It keeps the
# protocol the prepared application's Timekeeping::LocalReservations keeps,
# so either owner answers a call the same way:
#
# - all three are idempotent by (invoice_id, operation_id), and leave a
#   terminal receipt, `committed` or `aborted`, that every later call for the
#   operation answers unchanged;
# - an invoice has at most one unresolved operation: a new prepare carries the
#   earlier one's outcome in `resolves`, or is refused as retryable;
# - an abort of an operation never prepared is a no-op that still leaves an
#   `aborted` receipt (§9.3), and a commit of one is not-found.
#
# Each call is one transaction: admission under the carried generation
# (§10.1), then a per-invoice lock, then the invoice's tenant. During a
# handoff's settle step Timekeeping, as the outgoing owner, still admits a
# commit or abort carrying the old generation (§10.5 step 2,
# Ownership#settling?), and answers it only for an operation it registered:
# a commit of any other is refused as stale-generation. An abort of one is
# the no-op receipt it always is (§9.3), as the abort the existing
# application recorded for a prepare that never arrived here must be
# answered for settle to finish. A reservation
# change holds the entries it touches FOR UPDATE in id order, so it
# serializes with entry edits (§9.4), and gives every entry whose
# reservations changed its next version and outbox snapshot (§5.4), which
# carries the derived `locked` to the projection.
#
# Every call answers [status, body]. A refusal decided before anything is
# written raises Problem::Raised. A reservation-refused prepare is answered,
# not raised, so the outcome `resolves` carried for the earlier operation is
# kept: it is the existing application's durable fact either way.
module ReservationProtocol
  Rule = TimekeepingReservations

  # Who calls (the caller's verified token claims, whose company is the
  # call's), for which (invoice, operation), under which generation.
  Call = Data.define(:claims, :invoice_id, :operation_id, :generation) do
    def company_id = claims.fetch("company_id")
  end

  OUTCOMES = {
    "committed" => ->(operation, reservations) { Rule.commit(operation, reservations:) },
    "aborted" => ->(operation, reservations) { Rule.abort(operation, reservations:) }
  }.freeze

  # The entry facts line-item validation needs (reservation_api.json
  # prepared_entry), authoritative for existence and company (L8).
  PREPARED_FIELDS = %w[id company_id project_id user_id duration work_date version].freeze

  # `input` is the contract-checked prepare_request.
  def self.prepare(call, input)
    admitted(call) do
      same_company!(call, input.fetch("company_id"))
      operation = operation_of(call, input)
      record = find(call)
      next receipt(record) if record&.terminal?
      replayed_with_another_body!(call) if record && record.to_operation != operation

      settle_earlier!(call, input.fetch("resolves")) unless record
      reserve(operation, record, call.claims)
    end
  end

  def self.commit(call)
    admitted(call, settle: true) do |ownership|
      record = find(call) || unregistered!(call, ownership)
      record.terminal? ? receipt(record) : resolve(record, "committed", call.claims)
    end
  end

  def self.abort(call)
    admitted(call, settle: true) do
      record = find(call) || ReservationOperation.create!(
        invoice_id: call.invoice_id, operation_id: call.operation_id, company_id: call.company_id, state: "aborted"
      )
      record.terminal? ? receipt(record) : resolve(record, "aborted", call.claims)
    end
  end

  def self.admitted(call, settle: false)
    ReservationOperation.transaction do
      ownership = Ownership.admit!(call.generation, settle:)
      ReservationOperation.lock_invoice!(call.invoice_id)
      tenant!(call)
      yield ownership
    end
  end
  private_class_method :admitted

  # An invoice id belongs to the one company whose operations it holds
  # (§6.3). Invoice ids are global in the existing application, so another
  # company's call naming it is answered as if it did not exist.
  def self.tenant!(call)
    return unless ReservationOperation.where(invoice_id: call.invoice_id).where.not(company_id: call.company_id).exists?

    raise Problem::Raised, Problem.new(slug: "not-found", status: 404, detail: "no invoice #{call.invoice_id} in this company")
  end
  private_class_method :tenant!

  def self.same_company!(call, company_id)
    return if company_id == call.company_id

    raise Problem::Raised, Problem.new(slug: "forbidden", status: 403, detail: "company_id #{company_id} differs from the token's company")
  end
  private_class_method :same_company!

  def self.operation_of(call, input)
    Rule::Operation.new(
      invoice_id: call.invoice_id, operation_id: call.operation_id, company_id: call.company_id,
      kind: input.fetch("kind").to_sym, invoice_state: input.fetch("invoice_state").to_sym,
      entry_ids: input.fetch("entry_ids")
    )
  end
  private_class_method :operation_of

  def self.find(call)
    ReservationOperation.find_by(invoice_id: call.invoice_id, operation_id: call.operation_id)
  end
  private_class_method :find

  # The invoice's earlier unresolved operation, resolved with the outcome
  # `resolves` carries for it, or operation-unresolved (§5.3, §9.3).
  def self.settle_earlier!(call, resolves)
    earlier = ReservationOperation.state_prepared.find_by(invoice_id: call.invoice_id)
    return unless earlier
    unresolved!(earlier) unless resolves&.fetch("operation_id") == earlier.operation_id

    resolve(earlier, resolves.fetch("outcome"), call.claims)
  end
  private_class_method :settle_earlier!

  # What each answer of the rule's prepare leaves as the reservations.
  PREPARED = {
    Rule::Prepared => ->(result, _reservations) { result.reservations },
    Rule::Refused => ->(_result, reservations) { reservations }
  }.freeze

  def self.reserve(operation, record, claims)
    result, entries = change_reservations(operation, claims) do |facts, reservations|
      Rule.prepare(operation, entries: facts, reservations:).then { |answer| [PREPARED.fetch(answer.class).call(answer, reservations), answer] }
    end
    return refused(result) if result.is_a?(Rule::Refused)

    record || ReservationOperation.create!(**ReservationOperation.row_for(operation), state: "prepared")
    [200, { "status" => "prepared", "entries" => entries.values_at(*operation.entry_ids).map { |entry| prepared_entry(entry) } }]
  end
  private_class_method :reserve

  def self.resolve(record, outcome, claims)
    operation = record.to_operation
    change_reservations(operation, claims) { |_facts, reservations| [OUTCOMES.fetch(outcome).call(operation, reservations), nil] }
    record.update!(state: outcome)
    receipt(record)
  end
  private_class_method :resolve

  # Holds the entries the operation names or the invoice holds FOR UPDATE
  # in id order, then their reservations, and yields the rule's view of both.
  # The block answers the reservations after the change, and a result; only
  # the reservations that changed are written. Answers the result and the
  # held entries by id, as they now stand.
  def self.change_reservations(operation, claims)
    held = Reservation.where(invoice_id: operation.invoice_id).distinct.pluck(:entry_id)
    ids = (operation.entry_ids | held).sort
    entries = Entry.where(id: ids).order(:id).lock.to_a
    rows = Reservation.where(entry_id: ids).order(:id).lock.index_by(&:to_value)
    facts = entries.to_h { |entry| [entry.id, Rule::Entry.new(id: entry.id, company_id: entry.company_id)] }

    after, result = yield facts, rows.keys
    persist(rows, after)
    record_changes!(entries, rows.keys, after, claims)
    [result, entries.index_by(&:id)]
  end
  private_class_method :change_reservations

  # Deletes before inserting, so a reservation that replaces another never
  # meets it in a unique index.
  def self.persist(rows, after)
    stale = rows.except(*after).values
    fresh = after - rows.keys
    Reservation.where(id: stale.map(&:id)).delete_all if stale.any?
    Reservation.insert_all!(fresh.map { |value| Reservation.row_for(value) }) if fresh.any?
  end
  private_class_method :persist

  # Every entry whose reservations changed is its next version with its
  # outbox snapshot, which carries the derived `locked` (§5.4). `locked` is
  # not an audited column, so no audit row is written. updated_at moves only
  # when `locked` does, as today's `update!(locked:)` touches it only then.
  def self.record_changes!(entries, before, after, claims)
    changed = ((before - after) | (after - before)).to_set(&:entry_id)
    entries.select { |entry| changed.include?(entry.id) }.each do |entry|
      was_locked = Rule.locked?(entry.id, before)
      entry.reservations.reset
      entry.version += 1
      entry.save!(validate: false, touch: entry.locked? != was_locked)
      EntryChange.record!(entry, action: "update", audited_changes: {}, claims:)
    end
  end
  private_class_method :record_changes!

  def self.prepared_entry(entry)
    PREPARED_FIELDS.index_with { |field| Entry.contract_value(field, entry.public_send(field)) }
  end
  private_class_method :prepared_entry

  def self.receipt(record)
    [200, { "status" => record.state }]
  end
  private_class_method :receipt

  def self.refused(result)
    refused = result.refusals.map { |refusal| { "entry_id" => refusal.entry_id, "reason" => refusal.reason.to_s } }
    problem = Problem.new(
      slug: "reservation-refused", status: 409, refused:,
      detail: "prepare refused entry #{refused.pluck('entry_id').join(', ')}"
    )
    [409, problem.as_json]
  end
  private_class_method :refused

  def self.replayed_with_another_body!(call)
    raise Problem::Raised, Problem.new(
      slug: "idempotency-conflict", status: 409,
      detail: "operation #{call.operation_id} was prepared with another body"
    )
  end
  private_class_method :replayed_with_another_body!

  def self.unresolved!(earlier)
    raise Problem::Raised, Problem.new(
      slug: "operation-unresolved", status: 409, retryable: true,
      detail: "operation #{earlier.operation_id} of invoice #{earlier.invoice_id} is not resolved"
    )
  end
  private_class_method :unresolved!

  # A commit of an operation never prepared here: not-found under the
  # current generation, and stale under the settle step's exception, which
  # covers only an operation Timekeeping registered.
  def self.unregistered!(call, ownership)
    Ownership.refuse!("stale-generation", ownership, call.generation) if ownership.settling?(call.generation)
    not_prepared!(call)
  end
  private_class_method :unregistered!

  def self.not_prepared!(call)
    raise Problem::Raised, Problem.new(slug: "not-found", status: 404, detail: "operation #{call.operation_id} was never prepared")
  end
  private_class_method :not_prepared!
end
