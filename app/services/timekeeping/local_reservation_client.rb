# frozen_string_literal: true

# The `monolith` owner's side of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3, §9.2, §10.5): prepare of one
# ledger intent for the invoice reservation boundary, and commit and abort of
# one for the invoice operation worker (§9.2 step 4, §11.1), run in-process
# against the prepared application's reservation table
# (Timekeeping::LocalReservations over Timekeeping::LocalEntries), and
# answered exactly as Timekeeping::ReservationClient answers the
# `timekeeping` owner's calls over HTTP. The boundary therefore runs the same
# save order, the same retry and the same reconciliation, and the worker the
# same delivery, under either owner.
#
# - `prepared` answers ReservationClient::Prepared, with the desired set's
#   ReservationClient::PreparedEntry facts (L8).
# - A stored terminal receipt answers ReservationClient::Receipt, with the
#   contract's string status ("committed" or "aborted"), which the intent
#   reconciles (§9.2 step 3). Commit and abort answer the Receipt they
#   leave, which the worker matches against the delivery (§9.2 step 4).
# - Everything else raises the problem Timekeeping would answer, as
#   ReservationClient::Problem with a body the contract's problem allows:
#   reservation-refused with each refused entry (F1, L8), operation-unresolved
#   (retryable), idempotency-conflict for a replay with another body,
#   not-found for a commit of an operation never prepared here (an abort of
#   one is the no-op receipt of §9.3), and the admission refusals below.
#
# Admission (§10.1). Timekeeping admits each call under the generation it
# carries in X-Ownership-Generation. Here the provider runs in its own
# transaction, which holds the local ownership row FOR SHARE, so a handoff
# that raises the generation waits for it, and refuses it, as Timekeeping's
# copy refuses one, in the same order: stale-generation when the intent was
# admitted under another generation or this application does not own the
# entries, then ownership-moving while a handoff has admission closed. The
# reservation change runs inside that transaction, as a savepoint, so it
# commits with the admission or not at all. Commit and abort are admitted the
# same way, under the generation the intent was admitted under. The settle
# step's exception for an old-generation commit or abort (§10.5 step 2) is
# not taken here yet: one is refused as stale-generation, so it stays
# undelivered and the fence refuses to freeze.
#
# A reservation-refused prepare is answered by the local provider, not
# raised, so its transaction commits whatever the prepare's `resolves`
# resolved for the invoice's earlier operation, as Timekeeping keeps it. The
# problem is raised only after that commit.
#
class Timekeeping::LocalReservationClient
  Client = Timekeeping::ReservationClient
  Local = Timekeeping::LocalReservations

  # The local provider's answer => the boundary's: a value it reads, or the
  # problem it is raised as.
  ANSWERS = {
    Local::Prepared => ->(answer) { Client::Prepared.new(entries: answer.entries) },
    Local::Receipt => ->(answer) { Client::Receipt.new(status: answer.status.to_s) },
    Local::NotPrepared => ->(answer) {
      raise problem("not-found", 404, detail: "operation #{answer.operation_id} was never prepared")
    },
    Local::Unresolved => ->(answer) {
      raise problem("operation-unresolved", 409, retryable: true, detail: "operation #{answer.operation_id} is not resolved")
    },
    TimekeepingReservations::Refused => ->(answer) {
      refused = answer.refusals.map { |refusal| { "entry_id" => refusal.entry_id, "reason" => refusal.reason.to_s } }
      raise problem("reservation-refused", 409, refused:, detail: "prepare refused entry #{refused.pluck('entry_id').join(', ')}")
    }
  }.freeze

  def self.problem(slug, status, retryable: false, detail: nil, refused: nil)
    Client::Problem.new({
      "type" => Timekeeping::Contracts.problem_type(slug), "title" => Rack::Utils::HTTP_STATUS_CODES.fetch(status),
      "status" => status, "retryable" => retryable, "detail" => detail, "refused" => refused
    }.compact)
  end

  def initialize(reservations: Local.new(entries: Timekeeping::LocalEntries.new))
    @reservations = reservations
  end

  # §9.2 step 2, the call ReservationClient#prepare makes. `resolves` is nil,
  # or the intent's { "operation_id", "outcome" } for the invoice's earlier
  # undelivered operation (§5.3).
  def prepare(intent, invoice_state:, resolves:)
    answer = Timekeeping::Ownership.transaction do
      admit!(intent)
      @reservations.prepare(operation(intent, invoice_state), resolves: resolves&.symbolize_keys)
    rescue Local::ProtocolError => error
      raise self.class.problem("idempotency-conflict", 409, detail: error.message)
    end
    ANSWERS.fetch(answer.class).call(answer)
  end

  # §9.2 step 4, the calls ReservationClient#commit and #abort make: the
  # outcome the intent recorded, as its terminal receipt.
  def commit(intent) = resolve(:commit, intent)

  def abort(intent) = resolve(:abort, intent)

  private

    def resolve(call, intent)
      answer = Timekeeping::Ownership.transaction do
        admit!(intent)
        @reservations.public_send(call, invoice_id: intent.invoice_id, operation_id: intent.operation_id)
      end
      ANSWERS.fetch(answer.class).call(answer)
    end

    def admit!(intent)
      ownership = Timekeeping::Ownership.lock_shared!
      if intent.generation != ownership.generation || !ownership.owner_monolith?
        raise refusal("stale-generation", 409, ownership, intent)
      end
      raise refusal("ownership-moving", 503, ownership, intent, retryable: true) unless ownership.state_open?
    end

    def refusal(slug, status, ownership, intent, retryable: false)
      self.class.problem(slug, status, retryable:, detail: "operation #{intent.operation_id} carries generation #{intent.generation}; ownership is #{ownership.summary}")
    end

    def operation(intent, invoice_state)
      TimekeepingReservations::Operation.new(
        invoice_id: intent.invoice_id, operation_id: intent.operation_id, company_id: intent.company_id,
        kind: intent.kind.to_sym, invoice_state: invoice_state.to_sym, entry_ids: intent.entry_ids
      )
    end
end
