# frozen_string_literal: true

# The invoice reservation boundary of docs/architecture/timekeeping-soa.md
# §3.1 (W7) and §7: the one way an invoice save, discard or destroy changes
# the invoice's reservation set, in the save order of §9.2.
#
#   1. The pending intent is written in its own committed transaction
#      (Timekeeping::InvoiceOperation.open!), which takes the per-invoice
#      serialization lock.
#   2. The owner prepares the desired set, within the 2 s timeout, retried at
#      most twice with jitter and the same Idempotency-Key, only when the
#      answer was lost or a 5xx (§9.4). The prepare carries the outcome of the
#      invoice's earlier undelivered operation in `resolves` (§5.3).
#   3. Only on `prepared`: one transaction runs the invoice change, handed the
#      prepared entries for line-item validation (L8), and records the intent
#      `succeeded`. A prepare that answers a terminal receipt never re-runs
#      the change; the intent reconciles it.
#   4. Every failure path (a refusal, a timeout, a 5xx, a rollback, a failed
#      commit) records the intent `failed` while it is still pending, which
#      queues abort. Delivering commit or abort is the invoice operation
#      worker's (§11.1), never this boundary's.
#
# The owner is the one the ownership record names. `legacy` keeps today's
# lock callbacks (§3.1): the change runs as it does today and no intent is
# opened. `timekeeping` prepares over HTTP. `monolith` arrives with its own
# entry store (§10.5); until then the boundary refuses under it, as the
# gateway and the worker do.
class Timekeeping::InvoiceBoundary
  # One invoice operation that changes a reservation set. `entry_ids` is the
  # desired set (§7.2): every entry the invoice's remaining direct and grouped
  # lines reference after the change. Empty for discard and destroy.
  Change = Data.define(:invoice_id, :company_id, :kind, :invoice_state, :entry_ids) do
    def initialize(kind:, invoice_state:, entry_ids: [], **rest)
      raise ArgumentError, "unknown operation kind #{kind.inspect}" unless TimekeepingReservations::KINDS.include?(kind)
      raise ArgumentError, "unknown invoice state #{invoice_state.inspect}" unless TimekeepingReservations::INVOICE_STATES.include?(invoice_state)

      super(kind:, invoice_state:, entry_ids: entry_ids.uniq.freeze, **rest)
    end
  end

  # The change committed. `intent` is nil under `legacy`. `replayed` is true
  # when prepare answered the operation's own committed receipt: the change
  # ran before, and nothing ran now (§9.2 step 3).
  Result = Data.define(:intent, :value, :replayed)

  # The save failed, and the intent records it. `reason` is the problem
  # Timekeeping answered (:reservation_refused with `refused` for F1 and L8,
  # :operation_unresolved, :stale_generation, ...), or :unavailable,
  # :rolled_back, :aborted or :unreconciled. A retryable failure may succeed
  # on a later attempt of the whole save.
  class Failed < StandardError
    attr_reader :reason, :retryable, :refused

    def initialize(reason:, retryable:, refused: [], detail: nil)
      @reason, @retryable, @refused = reason, retryable, refused
      super(["invoice reservation #{reason.to_s.tr('_', ' ')}", detail].compact.join(": "))
    end
  end

  class OwnerUnavailable < StandardError; end

  PROVIDERS = { "timekeeping" => -> { Timekeeping::ReservationClient.new } }.freeze

  # Total attempts, as ApplicationJob counts them (§11.1): two retries (§9.4).
  PREPARE_ATTEMPTS = 3
  JITTER = 0.25.seconds

  # §9.2 step 3 for a prepare that answered a terminal receipt.
  RECONCILED = {
    succeeded: ->(intent) { Result.new(intent:, value: nil, replayed: true) },
    failed: ->(intent) { raise Failed.new(reason: :aborted, retryable: false, detail: "operation #{intent.operation_id} was aborted") },
    unreconciled: ->(intent) {
      raise Failed.new(reason: :unreconciled, retryable: true, detail: "operation #{intent.operation_id} is #{intent.state} here and resolved otherwise by its owner")
    }
  }.freeze

  def initialize(providers: PROVIDERS, pause: ->(attempt) { sleep(rand * JITTER * attempt) })
    @providers, @pause = providers, pause
  end

  # Runs the change under the current owner. The block is the invoice change:
  # it raises, or raises ActiveRecord::Rollback, to fail. It receives the
  # prepared entries, or nil under `legacy`, where today's validations decide.
  # Must run outside any application transaction, so the intent is durable
  # before prepare.
  def run(change, &)
    ownership = Timekeeping::Ownership.current
    return Result.new(intent: nil, value: yield(nil), replayed: false) if ownership.owner_legacy?

    provider = provider_for(ownership)
    raise Timekeeping::Ownership::Moving, I18n.t("timesheet_entry.ownership_moving") unless ownership.state_open?

    intent = Timekeeping::InvoiceOperation.open!(**change.to_h.slice(:invoice_id, :company_id, :kind, :entry_ids))
    failing(intent) { admitted_under!(intent, ownership) }
    perform(intent, invoice_state: change.invoice_state, provider:, &)
  end

  # Steps 2-4 for an intent already open: what a save runs after step 1, and
  # what a replay of the same operation runs again.
  def perform(intent, invoice_state:, provider: provider_for(Timekeeping::Ownership.current), &)
    if Timekeeping::InvoiceOperation.in_application_transaction?
      raise Timekeeping::InvoiceOperation::TransactionOrder, "operation #{intent.operation_id}: prepare must run outside the invoice transaction"
    end

    answer = failing(intent) { prepare(provider, intent, invoice_state) }
    return RECONCILED.fetch(intent.reconcile(answer.status)).call(intent) if answer.is_a?(Timekeeping::ReservationClient::Receipt)

    failing(intent) { apply(intent, answer.entries, &) }
  end

  private

    def provider_for(ownership)
      @providers.fetch(ownership.owner) do
        raise OwnerUnavailable, "invoice reservation boundary: owner #{ownership.owner} has no reservation provider yet"
      end.call
    end

    # The owner was chosen from an unlocked read, open with generation g. An
    # owner changes only at a flip, after a handoff raised the generation, so
    # the intent admitted under g was admitted under that same owner.
    def admitted_under!(intent, ownership)
      return if intent.generation == ownership.generation

      raise Timekeeping::Ownership::Moving, I18n.t("timesheet_entry.ownership_moving")
    end

    # §9.2 step 4: every failure records the durable outcome, then fails the
    # save. Under the per-invoice lock, nothing else can resolve the intent
    # but recovery, and record_failure! never overturns a recorded success.
    def failing(intent)
      yield
    rescue StandardError => error
      intent.record_failure!
      raise translate(error)
    end

    def prepare(provider, intent, invoice_state)
      resolves = intent.resolves
      (1..PREPARE_ATTEMPTS).each do |attempt|
        return provider.prepare(intent, invoice_state:, resolves:)
      rescue Faraday::Error, Timekeeping::ReservationClient::Problem => error
        raise unless attempt < PREPARE_ATTEMPTS && transient?(error)

        @pause.call(attempt)
      end
    end

    def transient?(error)
      error.is_a?(Faraday::Error) || error.status >= 500
    end

    # §9.2 step 3. A block that raised ActiveRecord::Rollback ends the
    # transaction without an error, and without success recorded.
    def apply(intent, entries)
      committed = false
      value = Timekeeping::InvoiceOperation.transaction do
        yield(entries).tap do
          intent.succeed!
          committed = true
        end
      end
      raise Failed.new(reason: :rolled_back, retryable: false, detail: "operation #{intent.operation_id}") unless committed

      Result.new(intent:, value:, replayed: false)
    end

    def translate(error)
      case error
      when Timekeeping::ReservationClient::Problem
        Failed.new(reason: error.type.tr("-", "_").to_sym, retryable: error.retryable, refused: error.refused, detail: error.message)
      when Faraday::Error then Failed.new(reason: :unavailable, retryable: true, detail: error.message)
      else error
      end
    end
end
