# frozen_string_literal: true

# The fence of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5) on Timekeeping's copy of the ownership record (§10.1), the only code
# that changes it. The handoff tool runs each step here and on the existing
# application's copy (Timekeeping::HandoffFence there); both copies move
# through the one state machine, TimekeepingReservations::Handoff.
#
# Each step is one transaction that takes the record FOR UPDATE, asks the
# step what to change, and writes it. Every mutating call holds the record
# FOR SHARE (Ownership.admit!), so close waits for the calls already
# admitted, and every call after it is refused as stale or moving.
#
# Waiting is bounded by `lock_timeout`, 60 s by default (§10.1). A call
# still admitted when it runs out leaves the step undone:
# ActiveRecord::LockWaitTimeout, and the record is unchanged.
module HandoffFence
  DRAIN_TIMEOUT = 60.seconds

  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # Runs one step against the record at `generation` and returns the record
  # as the step left it.
  def self.call(name, generation:, lock_timeout: DRAIN_TIMEOUT)
    step = TimekeepingReservations::Handoff::STEPS.fetch(name)

    Ownership.transaction(requires_new: true) do
      Ownership.connection.execute("SET LOCAL lock_timeout = '#{lock_timeout.in_milliseconds.to_i}ms'")
      Ownership.lock_exclusive!.tap { |ownership| ownership.update!(step.apply(ownership, generation:)) }
    end
  end
end
