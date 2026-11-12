# frozen_string_literal: true

# The fence of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5): the only code that changes this application's ownership record
# (§10.1). Each step is one transaction that takes the record FOR UPDATE,
# checks that the handoff is where the caller says it is, and moves it on:
#
#   close   step 1, open -> closed. Raises the generation. Every write holds
#           the record FOR SHARE (the gateway, the billing-write fence and
#           the operation intent all admit through Ownership.admit!), so the
#           exclusive lock waits for the writes already admitted, and every
#           write after it is refused as moving or stale.
#   freeze  step 3, closed -> frozen, only once settle
#           (Timekeeping::HandoffSettle) has resolved every registered invoice
#           operation and its owner has confirmed the outcome. While any
#           intent is pending or undelivered, freeze is refused as Unsettled
#           and nothing changes: no pending billing operation crosses the
#           handoff.
#   flip    step 7, frozen -> open under the incoming owner, once the
#           checkpoint is loaded and reconciled.
#   abort   closed or frozen -> open under the outgoing owner. The raised
#           generation stays, so commands admitted under the old one stay
#           refused and the gates that ask "has a handoff begun?" still say
#           yes (§10.1: "after an aborted handoff").
#
# Every step names the generation it expects to find, so a resumed handoff
# re-runs exactly the step that did not commit, and a second tool, or a step
# run twice, is refused and changes nothing. What the record holds is the
# step the handoff reached.
#
# Waiting is bounded by `lock_timeout`, 60 s by default (§10.1, "with the
# same 60 s timeout"). A write still admitted when it runs out leaves the step
# undone: ActiveRecord::LockWaitTimeout, and the record is unchanged.
#
# This is the local record only. The copy in Timekeeping's database, and the
# drain, checkpoint and reconcile steps between, belong to the handoff tool
# that calls these steps in order.
module Timekeeping::HandoffFence
  DRAIN_TIMEOUT = 60.seconds

  # The step was asked of a record that is not where the caller expects the
  # handoff to be. Nothing changed.
  class OutOfStep < StandardError; end

  # Freeze was asked while the invoice operation ledger still holds an intent
  # that is pending or whose outcome its owner has not confirmed (§10.5 step
  # 2). Nothing changed; settle again, or abort.
  class Unsettled < StandardError; end

  # Every owner has exactly one incoming owner (§3.1, §10.2): the first
  # cutover leaves legacy for good, rollback goes to the prepared
  # application, and re-cutover goes back to Timekeeping.
  SUCCESSORS = { "legacy" => "timekeeping", "timekeeping" => "monolith", "monolith" => "timekeeping" }.freeze

  # One row per step: the states it starts from, the state it leaves, what
  # else it changes on the record it locked, and what must already hold
  # before it may run (nil when it may, else why not).
  Step = Data.define(:from, :to, :change, :blocker) do
    def initialize(blocker: -> { }, **rest) = super
  end

  STEPS = {
    close: Step.new(from: %w[open], to: "closed", change: ->(ownership) { { generation: ownership.generation + 1 } }),
    freeze: Step.new(from: %w[closed], to: "frozen", change: ->(_) { {} }, blocker: -> { Timekeeping::InvoiceOperation.unsettled_summary }),
    flip: Step.new(from: %w[frozen], to: "open", change: ->(ownership) { { owner: SUCCESSORS.fetch(ownership.owner) } }),
    abort: Step.new(from: %w[closed frozen], to: "open", change: ->(_) { {} })
  }.freeze

  # Runs one step against the record at `generation` and returns the record
  # as the step left it.
  def self.call(name, generation:, lock_timeout: DRAIN_TIMEOUT)
    step = STEPS.fetch(name)

    Timekeeping::Ownership.transaction(requires_new: true) do
      Timekeeping::Ownership.connection.execute("SET LOCAL lock_timeout = '#{lock_timeout.in_milliseconds.to_i}ms'")
      ownership = Timekeeping::Ownership.lock_exclusive!
      ensure_in_step!(name, step.from, ownership, generation)
      ensure_ready!(name, step)
      ownership.tap { |locked| locked.update!(step.change.call(locked).merge(state: step.to)) }
    end
  end

  # Refuses with OutOfStep unless the record is at `generation` in one of the
  # `from` states. Settle, which changes no record, checks its place with it
  # too.
  def self.ensure_in_step!(name, from, ownership, generation)
    return if ownership.generation == generation && from.include?(ownership.state)

    raise OutOfStep,
      "Timekeeping handoff: #{name} expects generation #{generation} in state #{from.join(' or ')}, " \
      "found #{ownership.summary}; nothing changed"
  end

  def self.ensure_ready!(name, step)
    blocker = step.blocker.call
    raise Unsettled, "Timekeeping handoff: #{name} refused, #{blocker}; nothing changed" if blocker
  end
  private_class_method :ensure_ready!
end
