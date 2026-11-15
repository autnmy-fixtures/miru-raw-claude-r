# frozen_string_literal: true

# The prepared application's relay (docs/architecture/timekeeping-soa.md
# §5.4, §10.1, §15.1 D3): it delivers the local outbox's entry snapshots to
# the projection consumer, in batches of up to BATCH_SIZE in outbox order, as
# Timekeeping's OutboxRelay delivers Timekeeping's. It runs on its own queue
# and worker (Timekeeping::LocalRelayJob, config/solid_queue.yml).
#
# The outbox and the projection share this application's database, so the
# delivery is a call, not a request: one batch is one transaction that takes
# the undelivered rows FOR UPDATE SKIP LOCKED, so a second relay delivers
# other rows or none, applies them through Timekeeping::ProjectionConsumer,
# and marks them delivered. The consumer applying the batch and the rows'
# marks commit together or not at all.
#
# A batch is applied only as the projection endpoint would accept it: the
# entry snapshot contract's batch, applied whole by the consumer. One the
# contract refuses, the consumer refuses (§6.3), or the database refuses rolls
# back unmarked, stays at the head of the outbox, and is reported on every
# run until it is fixed. Nothing is ever skipped. The consumer upserts by
# (entry_id, version) and ignores anything not newer, so applying a batch
# twice, or out of order, is harmless.
#
# It reads no ownership: it drains whatever the outbox holds, which is only
# ever what the `monolith` owner wrote, and a handoff away from that owner
# drains it through its final position (§10.5 step 3) the same way. Nothing
# writes the outbox yet, so every run finds it empty.
class Timekeeping::LocalRelay
  BATCH_SIZE = 500 # the import batch's size (§3.4), as Timekeeping's relay
  CONTRACT = :entry_snapshot
  BATCH = "#/$defs/snapshot_batch"

  # A batch the projection did not take: nothing of it was applied or marked.
  class Undelivered < StandardError
    attr_reader :batch

    def initialize(message, batch:)
      @batch = batch
      super(message)
    end
  end

  Result = Data.define(:delivered, :undelivered)

  def initialize(batch_size: BATCH_SIZE, clock: -> { Time.current })
    @batch_size, @clock = batch_size, clock
  end

  # Delivers batch after batch until the outbox has no undelivered row left
  # that this relay can take, or a batch is not delivered. Answers how many
  # snapshots were delivered, and how many of the last batch were not.
  def run
    delivered = 0
    loop do
      sent = deliver_batch
      delivered += sent
      return Result.new(delivered:, undelivered: 0) if sent < @batch_size
    end
  rescue Undelivered => error
    Rails.logger.error("local relay: #{error.message}")
    Rails.error.report(error, handled: true, context: { relay: "local_outbox", delivered: })
    Result.new(delivered:, undelivered: error.batch)
  end

  private

    # The number of snapshots delivered: 0 when the outbox had nothing to take.
    def deliver_batch
      Timekeeping::OutboxSnapshot.transaction do
        rows = Timekeeping::OutboxSnapshot.undelivered.limit(@batch_size).lock("FOR UPDATE SKIP LOCKED").to_a
        next 0 if rows.empty?

        apply!(rows)
        Timekeeping::OutboxSnapshot.where(id: rows.map(&:id)).update_all(delivered_at: @clock.call)
        rows.size
      end
    end

    # Raises Undelivered, inside the batch's transaction so that it rolls
    # back, unless the consumer applied the whole batch.
    def apply!(rows)
      label = "outbox #{rows.first.id}..#{rows.last.id}, #{rows.size} snapshots, requests #{rows.map(&:request_id).uniq.join(', ')}"
      Rails.logger.info("local relay: #{label}")
      outcome = consume(rows.map(&:snapshot))
      return if outcome.is_a?(Timekeeping::ProjectionConsumer::Applied)

      raise Undelivered.new("#{label}: #{outcome}", batch: rows.size)
    rescue ActiveRecord::StatementInvalid => error
      raise Undelivered.new("#{label}: #{error.class}: #{error.message}", batch: rows.size)
    end

    # The consumer's outcome, or why the batch never reached it.
    def consume(snapshots)
      errors = Timekeeping::Contracts.errors(CONTRACT, BATCH, { "snapshots" => snapshots })
      return "the entry snapshot contract refuses the batch: #{errors.join('; ')}" if errors.any?

      outcome = Timekeeping::ProjectionConsumer.process(snapshots)
      return outcome unless outcome.is_a?(Timekeeping::ProjectionConsumer::Refused)

      "the projection refused entries #{outcome.entry_ids.join(', ')}: another company than the snapshot names"
    end
end
