# frozen_string_literal: true

# The fence of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5): the only code that changes this application's ownership record
# (§10.1). The steps and what each changes are the shared state machine,
# TimekeepingReservations::Handoff, which Timekeeping's copy of the record
# moves through too. Each step here is one transaction that takes the record
# FOR UPDATE, asks the step what to change, checks what must already hold
# here, and writes it:
#
#   close   Every write holds the record FOR SHARE (the gateway, the
#           billing-write fence and the operation intent all admit through
#           Ownership.admit!), so the exclusive lock waits for the writes
#           already admitted, and every write after it is refused as moving
#           or stale.
#   freeze  Only once settle (Timekeeping::HandoffSettle) has resolved every
#           registered invoice operation and its owner has confirmed the
#           outcome. While any intent is pending or undelivered, freeze is
#           refused as Unsettled and nothing changes: no pending billing
#           operation crosses the handoff.
#   flip    Once the checkpoint is loaded and reconciled.
#   abort   The raised generation stays, so the gates that ask "has a
#           handoff begun?" still say yes (§10.1: "after an aborted
#           handoff").
#
# What the record holds is the step the handoff reached.
#
# Waiting is bounded by `lock_timeout`, 60 s by default (§10.1, "with the
# same 60 s timeout"). A write still admitted when it runs out leaves the step
# undone: ActiveRecord::LockWaitTimeout, and the record is unchanged.
#
# This is the local record only. Timekeeping's copy has its own fence
# (services/timekeeping/app/services/handoff_fence.rb); the drain, checkpoint
# and reconcile steps between belong to the handoff tool that calls both in
# order.
module Timekeeping::HandoffFence
  DRAIN_TIMEOUT = 60.seconds

  OutOfStep = TimekeepingReservations::Handoff::OutOfStep

  # Freeze was asked while the invoice operation ledger still holds an intent
  # that is pending or whose outcome its owner has not confirmed (§10.5 step
  # 2). Nothing changed; settle again, or abort.
  class Unsettled < StandardError; end

  # What must already hold in this application before a step may run: nil
  # when it may, else why not. A step not listed may always run.
  BLOCKERS = { freeze: -> { Timekeeping::InvoiceOperation.unsettled_summary } }.freeze

  # Runs one step against the record at `generation` and returns the record
  # as the step left it.
  def self.call(name, generation:, lock_timeout: DRAIN_TIMEOUT)
    step = TimekeepingReservations::Handoff::STEPS.fetch(name)

    Timekeeping::Ownership.transaction(requires_new: true) do
      Timekeeping::Ownership.connection.execute("SET LOCAL lock_timeout = '#{lock_timeout.in_milliseconds.to_i}ms'")
      ownership = Timekeeping::Ownership.lock_exclusive!
      changes = step.apply(ownership, generation:)
      ensure_ready!(name)
      ownership.tap { |locked| locked.update!(changes) }
    end
  end

  def self.ensure_ready!(name)
    blocker = BLOCKERS[name]&.call
    raise Unsettled, "Timekeeping handoff: #{name} refused, #{blocker}; nothing changed" if blocker
  end
  private_class_method :ensure_ready!
end
