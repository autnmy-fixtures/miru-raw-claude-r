# frozen_string_literal: true

# Settle, step 2 of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5): "resolve every registered invoice operation from its durable
# outcome", so no pending billing operation crosses the handoff. It runs
# between close and freeze, while the record is closed at the generation
# close raised, and changes no ownership record.
#
# It is one sweep of the invoice operation worker (§11.1) with no time limit:
#
#   1. Every pending intent is resolved now, not only those past the save's
#      time limit. Close drained every billing write already admitted and
#      refuses the rest (§10.1), so no save can still record success: its
#      invoice change is refused as moving before it reaches the intent. The
#      worker's #record_failure! takes each intent FOR UPDATE, so a success
#      recorded first is never overturned.
#   2. Every outcome not yet delivered goes to the outgoing owner, which the
#      record still names until the flip, as commit or abort carrying the
#      generation the intent was admitted under. That is the old generation:
#      the one owner-side exception of this step ("the outgoing owner still
#      applies a commit or abort that carries the old generation, and only
#      for an operation it registered").
#
# Answers the worker's Result. A delivery that fails stays undelivered and is
# listed there; the fence then refuses to freeze (HandoffFence::Unsettled),
# and settle runs again, or the handoff aborts. Running it again is safe:
# recovery and delivery are idempotent by operation.
#
# Delivery to the `monolith` owner arrives with its entry store, so a settle
# with anything to deliver under it is refused, as the worker refuses.
module Timekeeping::HandoffSettle
  STATES = %w[closed].freeze

  def self.call(generation:, worker: Timekeeping::InvoiceOperationWorker.new(time_limit: 0.seconds))
    Timekeeping::HandoffFence.ensure_in_step!(:settle, STATES, Timekeeping::Ownership.current, generation)
    worker.run
  end
end
