# frozen_string_literal: true

# Timekeeping's side of the observability table of
# docs/architecture/timekeeping-soa.md §11.3: what it measures of itself, and
# the alert each signal raises. The existing application measures its own
# side (Timekeeping::Signals there).
#
# | Signal                                       | Alert                       |
# |----------------------------------------------|-----------------------------|
# | Relay lag of Timekeeping's outbox            | > 60 s for 5 min            |
# | Stale-generation refusals outside a handoff  | any                         |
# | Reconciliation differences                   | any (aborts the handoff)    |
#
# Relay lag is the distance between the latest outbox position and the
# position delivered through, in time: how long the oldest snapshot not yet
# delivered has waited, so 0 when the relay is caught up. A snapshot written
# at c and delivered at d holds the lag above the limit over (c + limit, d),
# or up to now while it is undelivered. The alert holds when the lag is above
# the limit now and those intervals cover the whole window, so it is read
# from the outbox rows alone, with no sample kept between runs, and a
# restarted reader sees the same answer. It is read by SignalsJob, on the
# relay's own worker, the only worker Timekeeping runs (§11.1): it catches a
# relay that runs but cannot deliver (the consumer refuses or is down). A
# worker that has stopped reads nothing, so it is seen by its absence, and by
# `bin/rails timekeeping:signals`, which any process of the image can run.
#
# A stale-generation refusal is expected only while a handoff is raising the
# generation. Both copies of the ownership record move through one state
# machine (TimekeepingReservations::Handoff): each closes at the handoff's
# first step and reopens only at its flip or its abort, so while this copy
# is closed or frozen a handoff is in progress, and a refusal it makes while
# open is one outside a handoff: a call under an old generation after the
# handoff has finished, or any mutating call while Timekeeping does not own
# entries (before the first cutover, after a rollback), when nothing should
# be calling it at all. It is reported as it happens, from the record the
# refusal read under its lock (Ownership::Refused#ownership), not polled.
#
# A reconciliation difference already aborts the handoff that finds it: the
# handoff API answers it as checkpoint-differs, and the handoff tool aborts.
# It is also reported here, as it is found.
#
# Every alert is reported through Rails.error, which Sentry receives with the
# `service` tag (config/initializers/sentry.rb), and logged at error level,
# which is what the local demo, where Sentry is not enabled, shows. The
# relay's lag is reported again on every run while it holds.
class Signals
  RELAY_LAG_LIMIT = 60.seconds
  RELAY_LAG_WINDOW = 5.minutes

  POLLED = %i[relay_lag].freeze

  # One alert of §11.3.
  class Alert < StandardError
    attr_reader :signal, :details

    def initialize(signal, message, **details)
      @signal, @details = signal, details
      super("Timekeeping signal #{signal}: #{message}")
    end
  end

  # What one read found. Lag is in seconds; backlog in outbox positions.
  Reading = Data.define(:relay_lag, :relay_backlog, :relay_lag_sustained, :ownership)

  # Reports `refused`, an Ownership::Refused answered to `request`, when it
  # is a stale-generation refusal and the record it read was open, so no
  # handoff was in progress. Answers whether it reported.
  def self.stale_generation_refused(refused, request:)
    ownership = refused.ownership
    return false unless refused.problem.slug == "stale-generation" && ownership&.state_open?

    report(
      Alert.new(
        :stale_generation,
        "#{request.request_method} #{request.path} was refused (#{refused.problem.detail}) with no handoff in progress",
        request_id: request.request_id, ownership: ownership.summary
      )
    )
    true
  end

  # Reports a reconciliation difference (CheckpointReconcile::Differs) found
  # for `request`; the handoff it belongs to is aborted by its tool.
  def self.reconciliation_differs(differs, request:)
    report(
      Alert.new(
        :reconciliation_differences, "#{request.request_method} #{request.path}: #{differs.message}",
        request_id: request.request_id, lists: differs.lists
      )
    )
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
      ownership: Ownership.current.summary
    )
  end

  # The alerts the polled signals hold now.
  def alerts
    reading = read
    POLLED.filter_map { |signal| public_send(:"#{signal}_alert", reading) }
  end

  # Reports every alert the polled signals hold now, and answers them.
  def report!
    alerts.each { |alert| self.class.report(alert) }
  end

  def relay_lag_alert(reading)
    return unless reading.relay_lag_sustained

    Alert.new(
      :relay_lag,
      "the outbox relay has been more than #{RELAY_LAG_LIMIT.inspect} behind for #{RELAY_LAG_WINDOW.inspect} " \
        "(#{reading.relay_lag.round(1)} s now, #{reading.relay_backlog} position(s) undelivered)",
      lag: reading.relay_lag, backlog: reading.relay_backlog
    )
  end

  private

    def undelivered_snapshots = OutboxSnapshot.where(delivered_at: nil)

    def relay_lag(now)
      oldest = undelivered_snapshots.minimum(:created_at)
      oldest ? [now - oldest, 0.0].max.to_f : 0.0
    end

    # Latest outbox position minus the position delivered through: every
    # position after the first undelivered one, up to the latest.
    def relay_backlog
      first_undelivered = undelivered_snapshots.minimum(:id)
      first_undelivered ? OutboxSnapshot.maximum(:id) - first_undelivered + 1 : 0
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
      written = OutboxSnapshot.where(created_at: ...(now - RELAY_LAG_LIMIT))
      oldest_undelivered = written.where(delivered_at: nil).order(:created_at).limit(1).pluck(:created_at, :delivered_at)
      delivered = written.where(delivered_at: (now - RELAY_LAG_WINDOW)..).pluck(:created_at, :delivered_at)
      (delivered + oldest_undelivered).sort_by(&:first)
    end
end
