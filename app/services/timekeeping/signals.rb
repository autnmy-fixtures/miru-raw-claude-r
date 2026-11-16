# frozen_string_literal: true

# The existing application's side of the observability table of
# docs/architecture/timekeeping-soa.md §11.3: what it measures of its own
# Timekeeping machinery, and the alert each signal raises.
#
# | Signal                                             | Alert                  |
# |----------------------------------------------------|------------------------|
# | Relay lag of the prepared application's outbox     | > 60 s for 5 min       |
# | `invoice_operations` pending older than 60 s       | any                    |
# | Undelivered commit or abort                        | any older than 60 s    |
# | Stale-generation refusals outside a handoff        | any                    |
#
# Relay lag is the distance between the latest outbox position and the
# position delivered through, in time: how long the oldest snapshot not yet
# delivered has waited, so 0 when the relay is caught up. A snapshot written
# at c and delivered at d holds the lag above the limit over (c + limit, d),
# or up to now while it is undelivered. The alert holds when the lag is above
# the limit now and those intervals cover the whole window, so it is read
# from the outbox rows alone, with no sample kept between runs, and a
# restarted reader sees the same answer. The outbox is written only by the
# `monolith` owner (after a rollback), so under any other owner it is drained
# and the lag is 0. Timekeeping measures its own outbox on its side.
#
# An operation is pending from the save's step 1 until a save, recovery or
# settle resolves it (§9.2); recovery resolves one past the save's time limit
# (Timekeeping::InvoiceOperationWorker::SAVE_TIME_LIMIT, 30 s), so one pending
# past 60 s means the invoice operation worker is not sweeping. An outcome is
# undelivered from the moment it is recorded (its updated_at, the last change
# to an undelivered row) until its owner confirms it.
#
# A stale-generation refusal is expected only while a handoff is raising the
# generation. This application's copy of the ownership record closes first in
# every handoff (§10.5) and stays closed until its flip: the last step when
# Timekeeping is the incoming owner, and the first of the two flips in a
# rollback, after which every write and delivery goes to the `monolith` owner
# here and nothing is sent to Timekeeping under a generation. So a refusal
# seen while that copy is open is one outside a handoff. It is reported as it
# happens (.stale_generation_refused), not polled.
#
# Every alert is reported through Rails.error, which Sentry receives with the
# `service` tag (config/initializers/sentry.rb), and logged at error level,
# which is what the local demo, where Sentry is not enabled, shows. The
# polled signals are reported again on every run while they hold.
#
# Reconciliation differences already abort the handoff that finds them, and
# the single-writer guard runs as a spec (spec/requests/timekeeping/
# single_writer_guard_spec.rb); neither is a signal read here.
class Timekeeping::Signals
  RELAY_LAG_LIMIT = 60.seconds
  RELAY_LAG_WINDOW = 5.minutes
  OPERATION_AGE_LIMIT = 60.seconds

  # The signals each dedicated worker reads. Each watches the other's work, so
  # a worker that stops is noticed by the one still running: the relay's lag
  # is read on the invoice operation worker (Timekeeping::RelaySignalJob), and
  # the ledger on the relay worker (Timekeeping::InvoiceOperationSignalsJob).
  RELAY = %i[relay_lag].freeze
  INVOICE_OPERATIONS = %i[pending_operations undelivered_outcomes].freeze
  POLLED = (RELAY + INVOICE_OPERATIONS).freeze

  # One alert of §11.3.
  class Alert < StandardError
    attr_reader :signal, :details

    def initialize(signal, message, **details)
      @signal, @details = signal, details
      super("Timekeeping signal #{signal}: #{message}")
    end
  end

  # What one read found. Lag is in seconds; backlog in outbox positions.
  Reading = Data.define(
    :relay_lag, :relay_backlog, :relay_lag_sustained, :pending_operations, :undelivered_outcomes, :ownership
  )

  # Reports `problem` when it is a stale-generation refusal and this
  # application's ownership copy is open, so no handoff is in progress.
  # Answers the problem, so a caller can raise what it was given.
  # `ownership` is the record the caller already holds, if any.
  def self.stale_generation_refused(problem, source:, ownership: nil)
    return problem unless problem.type == "stale-generation"

    ownership ||= Timekeeping::Ownership.current
    return problem unless ownership.state_open?

    report(
      Alert.new(
        :stale_generation, "#{source} was refused (#{problem.message}) with no handoff in progress (#{ownership.summary})",
        source:, ownership: ownership.summary
      )
    )
    problem
  end

  def self.report(alert)
    Rails.logger.error(alert.message)
    Rails.error.report(alert, handled: true, severity: :error, context: { signal: alert.signal, **alert.details })
  end

  def initialize(clock: -> { Time.current })
    @clock = clock
  end

  def read
    now = @clock.call
    lag = relay_lag(now)
    Reading.new(
      relay_lag: lag, relay_backlog:, relay_lag_sustained: lag > RELAY_LAG_LIMIT && relay_lag_sustained?(now),
      pending_operations: pending_operations(now), undelivered_outcomes: undelivered_outcomes(now),
      ownership: Timekeeping::Ownership.current.summary
    )
  end

  # The alerts the `signals` hold now.
  def alerts(signals = POLLED)
    reading = read
    signals.filter_map { |signal| public_send(:"#{signal}_alert", reading) }
  end

  # Reports every alert the `signals` hold now, and answers them.
  def report!(signals = POLLED)
    alerts(signals).each { |alert| self.class.report(alert) }
  end

  def relay_lag_alert(reading)
    return unless reading.relay_lag_sustained

    Alert.new(
      :relay_lag,
      "the local outbox relay has been more than #{RELAY_LAG_LIMIT.inspect} behind for #{RELAY_LAG_WINDOW.inspect} " \
        "(#{reading.relay_lag.round(1)} s now, #{reading.relay_backlog} position(s) undelivered)",
      lag: reading.relay_lag, backlog: reading.relay_backlog
    )
  end

  def pending_operations_alert(reading)
    pending = reading.pending_operations
    return if pending.empty?

    Alert.new(
      :pending_operations,
      "#{pending.size} invoice operation(s) pending for more than #{OPERATION_AGE_LIMIT.inspect}: #{pending.join(', ')}",
      operation_ids: pending
    )
  end

  def undelivered_outcomes_alert(reading)
    undelivered = reading.undelivered_outcomes
    return if undelivered.empty?

    listed = undelivered.map { |operation_id, delivery| "#{delivery} #{operation_id}" }
    Alert.new(
      :undelivered_outcomes,
      "#{undelivered.size} commit or abort undelivered for more than #{OPERATION_AGE_LIMIT.inspect}: #{listed.join(', ')}",
      operations: undelivered.to_h
    )
  end

  private

    def undelivered_snapshots = Timekeeping::OutboxSnapshot.where(delivered_at: nil)

    def relay_lag(now)
      oldest = undelivered_snapshots.minimum(:created_at)
      oldest ? [now - oldest, 0.0].max.to_f : 0.0
    end

    # Latest outbox position minus the position delivered through: every
    # position after the first undelivered one, up to the latest.
    def relay_backlog
      first_undelivered = undelivered_snapshots.minimum(:id)
      first_undelivered ? Timekeeping::OutboxSnapshot.maximum(:id) - first_undelivered + 1 : 0
    end

    # Whether the lag stayed above the limit at every moment of the window
    # before now (the caller checks now itself: a backlog delivered this
    # instant ends the alert).
    def relay_lag_sustained?(now)
      covered = now - RELAY_LAG_WINDOW
      lagging_intervals(now).each do |created_at, delivered_at|
        return false if created_at + RELAY_LAG_LIMIT > covered

        covered = [covered, delivered_at || now].max
        return true if covered >= now
      end
      false
    end

    # [created_at, delivered_at] of every snapshot that held the lag above the
    # limit at some moment of the window, oldest first: written more than the
    # limit ago, and undelivered, or delivered within the window. Of the
    # undelivered ones only the oldest matters, since it is lagging through
    # now.
    def lagging_intervals(now)
      written = Timekeeping::OutboxSnapshot.where(created_at: ...(now - RELAY_LAG_LIMIT))
      oldest_undelivered = written.where(delivered_at: nil).order(:created_at).limit(1).pluck(:created_at, :delivered_at)
      delivered = written.where(delivered_at: (now - RELAY_LAG_WINDOW)..).pluck(:created_at, :delivered_at)
      (delivered + oldest_undelivered).sort_by(&:first)
    end

    def pending_operations(now)
      Timekeeping::InvoiceOperation.pending_before(now - OPERATION_AGE_LIMIT).order(:id).pluck(:operation_id)
    end

    # [operation_id, delivery] of every outcome undelivered past the limit.
    def undelivered_outcomes(now)
      Timekeeping::InvoiceOperation.undelivered.where(updated_at: ...(now - OPERATION_AGE_LIMIT)).order(:id)
        .pluck(:operation_id, :state).map { |operation_id, state| [operation_id, Timekeeping::InvoiceOperation::DELIVERIES.fetch(state)] }
    end
end
