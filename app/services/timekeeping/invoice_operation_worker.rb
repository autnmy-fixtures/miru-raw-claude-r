# frozen_string_literal: true

# The invoice operation worker of docs/architecture/timekeeping-soa.md §11.1:
# one sweep over the operation intent ledger (§9.1), run on its own
# `invoice_operations` queue by Timekeeping::InvoiceOperationsJob.
#
#   1. Recovery (§9.2): every intent still pending past the save's time
#      limit is resolved from its durable outcome. Timekeeping::InvoiceOperation
#      #record_failure! takes it FOR UPDATE, so recovery waits for a save
#      still in its step-3 transaction, and records `failed`, which queues
#      abort, only when no save recorded success first. Elapsed time alone
#      never releases a reservation: it only decides when recovery looks.
#   2. Delivery (§9.2 step 4): every outcome not yet delivered is sent to the
#      owner, `succeeded` as commit and `failed` as abort, carrying the
#      generation the intent was admitted under. Only the receipt that matches
#      the delivery marks it delivered. Any other answer, or none, leaves it
#      undelivered, is reported, and is sent again by the next sweep, with the
#      same Idempotency-Key, until it is answered. One intent's failure never
#      holds back another's.
#
# The owner is the one the ownership record names now. Only `timekeeping`
# has a reservation provider over the wire so far. `monolith` arrives with its
# own entry store (§10.5), and `legacy` keeps today's callbacks and opens no
# intent. A sweep with something to deliver under either is refused, after
# recovery, and nothing is marked delivered.
class Timekeeping::InvoiceOperationWorker
  # How long a save may hold its intent pending: three prepare attempts of at
  # most 2 s each with jitter (§9.4), then the invoice transaction. Past it,
  # recovery resolves the intent, well inside the 60 s alert of §11.3. Racing
  # a slow save is safe, only unkind: the save then fails, retryable.
  SAVE_TIME_LIMIT = 30.seconds

  OWNERS = { "timekeeping" => -> { Timekeeping::ReservationClient.new } }.freeze

  # The receipt that confirms each delivery (§5.3).
  CONFIRMED_BY = { commit: "committed", abort: "aborted" }.freeze

  # A delivery answered, or not, in a way that leaves it undelivered.
  UNDELIVERED = [Timekeeping::ReservationClient::Error, Faraday::Error, ActiveRecord::RecordNotFound].freeze

  class OwnerUnavailable < StandardError; end

  # The owner answered with a receipt other than the one the delivery asks
  # for, so the two sides disagree on the operation's outcome.
  class OutcomeMismatch < StandardError; end

  Result = Data.define(:recovered, :delivered, :undelivered)

  def initialize(owners: OWNERS, time_limit: SAVE_TIME_LIMIT, clock: -> { Time.current })
    @owners, @time_limit, @clock = owners, time_limit, clock
  end

  def run
    recovered = Timekeeping::InvoiceOperation.recover!(before: @clock.call - @time_limit)
    intents = Timekeeping::InvoiceOperation.undelivered.order(:created_at, :id).to_a
    provider = owner if intents.any?
    delivered, undelivered = intents.partition { |intent| deliver(provider, intent) }

    Result.new(recovered:, delivered: delivered.map(&:operation_id), undelivered: undelivered.map(&:operation_id))
  end

  private

    def owner
      name = Timekeeping::Ownership.current.owner
      @owners.fetch(name) { raise OwnerUnavailable, "invoice operation worker: owner #{name} has no reservation provider yet, nothing delivered" }.call
    end

    # True once the owner confirmed the outcome and the intent is marked
    # delivered; false when it stays queued for the next sweep.
    def deliver(owner, intent)
      call = intent.delivery
      receipt = owner.public_send(call, intent)
      unless receipt.status == CONFIRMED_BY.fetch(call)
        raise OutcomeMismatch, "#{call} of operation #{intent.operation_id} answered #{receipt.status}"
      end

      intent.mark_delivered!
      true
    rescue OutcomeMismatch, *UNDELIVERED => error
      Rails.error.report(error, handled: true, severity: :warning, context: report_context(intent, call))
      false
    end

    def report_context(intent, call)
      { service: "invoice_operations", operation_id: intent.operation_id, invoice_id: intent.invoice_id, delivery: call }
    end
end
