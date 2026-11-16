# frozen_string_literal: true

# The handoff tool for the re-cutover, monolith -> timekeeping
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5). It runs the
# procedure's steps in order on both copies of the ownership record (§10.1):
# this application's, through Timekeeping::HandoffFence, and Timekeeping's,
# through Timekeeping::HandoffClient, because the two applications share no
# database (§11.2). The outgoing owner is the prepared application here, so
# the checkpoint is taken on this side (Timekeeping::LocalCheckpoint) and
# carried to Timekeeping, the incoming owner again, to load and reconcile.
#
#   close_local    1. close admission here, where every write enters (the
#                     gateway and the billing-write fence), and take the
#                     financial snapshot once the close has drained every
#                     billing write already admitted (§10.1, §13 item 2)
#   close_remote      close Timekeeping's copy at the same generation
#   freeze_local   2. settle every registered invoice operation
#                     (Timekeeping::HandoffSettle): the `monolith` owner, the
#                     outgoing one, still applies their commit or abort under
#                     the old generation while this copy is closed
#                     (Timekeeping::Ownership#settling?); 3. then freeze here
#   freeze_remote     freeze Timekeeping's copy
#   transfer          wait for the local relay (Timekeeping::LocalRelay, on
#                     its own worker) to deliver the prepared application's
#                     outbox into timesheet_entries (§10.5 step 3); 4. take
#                     the checkpoint out of the prepared tables
#                     (Timekeeping::LocalCheckpoint) and load it into
#                     Timekeeping (HandoffClient#load_recutover_checkpoint),
#                     5. which sets its id sequences; 6. reconcile on both
#                     sides (Timekeeping's, then Timekeeping::
#                     RecutoverReconcile), and check that both counted every
#                     part alike
#   flip_remote    7. flip Timekeeping's copy, the incoming owner, first
#   flip_local        then this one
#
# The incoming owner flips first, as in the first cutover. Between the two
# flips this side is still frozen and refuses every write as moving (503,
# retryable), so no write is routed to an owner that has handed its entries
# over, and none reaches Timekeeping through this application before it
# owns them.
#
# It resumes. Every run starts by reading both copies, and where they stand
# names the one step to run next (POSITIONS); a step that committed is never
# run again. Repeating `transfer` is safe: the take is a read of a frozen
# prepared application, so it carries the same checkpoint each time;
# Timekeeping's re-cutover load replaces what it holds with what is carried,
# so loading the same checkpoint again leaves the same tables; and both
# reconciles write nothing. So no checkpoint is kept for a resume: a resumed
# transfer takes it again.
#
# What a run does on failure:
#
# - A refusal that a retry cannot change aborts the handoff on both copies
#   (§10.5 step 6) and raises Aborted with what was found: an operation
#   settle left unresolved in the prepared tables (LocalCheckpoint::
#   Unsettled, at the take), a checkpoint Timekeeping refused to load
#   (checkpoint-refused), a reconcile difference on either side, or two
#   reconciles that counted the parts differently. The raised generation
#   stays, so commands admitted under the old one stay refused.
# - Anything else leaves both copies fenced where they are and raises:
#   Timekeeping unreachable (HandoffClient::Unavailable), a step whose lock
#   waited out the writes already admitted (ActiveRecord::LockWaitTimeout, or
#   Timekeeping's drain-timeout), a settle that could not deliver every
#   outcome (HandoffFence::Unsettled), or a local relay that did not drain in
#   time (DrainTimeout). Run again to resume, or #abort! to reopen admission.
#
# An abort reopens both copies under the `monolith` owner. If the load had
# run, Timekeeping still holds that checkpoint; it owns nothing, and a later
# re-cutover's load replaces it with what the prepared application then
# holds.
#
# The financial snapshot is the "before" of the money check. A run that
# starts at close_local takes it; a resumed run is given the one taken before
# the interruption (its journal's), or takes it itself. Both are taken while
# admission is closed, and no billing write is admitted then (§10.1), so
# either is the state the handoff must leave unchanged. The journal has the
# first cutover's interface (Timekeeping::FirstCutover::MemoryJournal by
# default): it is told an empty Resume as a handoff starts, so nothing an
# earlier handoff took is resumed into this one, then the snapshot as soon as
# it is taken.
#
# Its last position, done, is "Timekeeping owns entries, open, at the
# generation both copies hold", whichever handoff left them there; a run
# there changes nothing, as a run of the other tools at their own done does.
class Timekeeping::Recutover
  # The run cannot go on from where it stands: both copies are where no step
  # of this re-cutover leaves them. Nothing was changed.
  class Unresumable < StandardError; end

  # The local relay had not delivered the prepared application's outbox into
  # timesheet_entries when the wait ran out. Both copies stay frozen; run
  # again to resume.
  class DrainTimeout < StandardError; end

  # The handoff was aborted on both copies. `step` names what refused, and
  # `lists` what it found, by check (§10.4).
  class Aborted < StandardError
    attr_reader :step, :lists

    def initialize(step, lists, reason)
      @step, @lists = step, lists
      super("Timekeeping re-cutover aborted at #{step}: #{reason}")
    end
  end

  # Timekeeping's reconcile and this side's counted the parts of one
  # checkpoint differently. `lists` names each part that differs.
  class CountsDiffer < StandardError
    attr_reader :lists

    def initialize(remote, local)
      parts = remote.to_h.keys.reject { |part| remote.to_h[part] == local.to_h[part] }
      @lists = { receipt_differs: parts.map(&:to_s) }
      super("Timekeeping reconciled #{remote.to_h.slice(*parts)}, this application #{local.to_h.slice(*parts)}")
    end
  end

  # The generation the handoff raised to, and what this side's reconcile
  # counted (Timekeeping::RecutoverReconcile::Reconciled, which Timekeeping's
  # receipt matched), nil when the run resumed after the reconcile had
  # already passed.
  Result = Data.define(:generation, :reconciled)

  # What an interrupted run took, for its resume: the financial snapshot, nil
  # until taken.
  Resume = Data.define(:financial_snapshot) do
    def initialize(financial_snapshot: nil)
      super
    end
  end

  Drain = Timekeeping::FirstCutover::Drain
  MemoryJournal = Timekeeping::FirstCutover::MemoryJournal

  STEPS = %i[close_local close_remote freeze_local freeze_remote transfer flip_remote flip_local].freeze

  # Where the re-cutover at generation g stands, as (owner, state,
  # generation - g) of this application's copy and Timekeeping's, and the
  # step that runs next. A step that is not listed is never where a run
  # stops: transfer runs again until flip_remote commits.
  POSITIONS = {
    close_local: [["monolith", "open", -1], ["monolith", "open", -1]],
    close_remote: [["monolith", "closed", 0], ["monolith", "open", -1]],
    freeze_local: [["monolith", "closed", 0], ["monolith", "closed", 0]],
    freeze_remote: [["monolith", "frozen", 0], ["monolith", "closed", 0]],
    transfer: [["monolith", "frozen", 0], ["monolith", "frozen", 0]],
    flip_local: [["monolith", "frozen", 0], ["timekeeping", "open", 0]],
    done: [["timekeeping", "open", 0], ["timekeeping", "open", 0]]
  }.freeze

  # Timekeeping's refusals that no retry changes (handoff_api.json), and the
  # step each names.
  REFUSED = { "checkpoint-refused" => :load, "checkpoint-differs" => :reconcile_remote }.freeze

  # The states of a copy a handoff has fenced, which abort reopens.
  FENCED = Timekeeping::FirstCutover::FENCED

  POLL_INTERVAL = Timekeeping::FirstCutover::POLL_INTERVAL

  attr_reader :financial_snapshot

  # `journal` holds what an interrupted run took: the run starts from its
  # `resume`, and tells it `record(resume)` each time it takes something.
  # `drain` bounds the wait for the local relay.
  def initialize(client: Timekeeping::HandoffClient.new, journal: MemoryJournal.new(Resume.new), drain: Drain.new, logger: Rails.logger)
    @client, @journal, @drain, @logger = client, journal, drain, logger
    @financial_snapshot = journal.resume.financial_snapshot
  end

  # What a later run needs to resume this one.
  def resume = Resume.new(financial_snapshot:)

  # Runs every step from where the two copies stand to the end, and answers
  # the Result.
  def call
    position, generation = locate(Timekeeping::Ownership.current, @client.status.copy)
    reconciled = nil

    STEPS.drop(STEPS.index(position) || STEPS.size).each do |step|
      log("#{step} at generation #{generation}")
      outcome = send(step, generation)
      reconciled = outcome if step == :transfer
    end

    Result.new(generation:, reconciled:)
  end

  # Reopens admission on every copy the handoff has fenced, Timekeeping's
  # first, at the generation it raised to, both still under the `monolith`
  # owner. Unresumable when no re-cutover is in progress, or once a copy has
  # flipped: past the flip the handoff only goes forward. Answers that
  # generation.
  def abort!
    local, remote = Timekeeping::Ownership.current, @client.status.copy
    generation = local.generation
    in_progress = local.owner == "monolith" && FENCED.include?(local.state) && remote.owner == "monolith"
    raise Unresumable, "Timekeeping re-cutover: nothing to abort, #{describe(local, remote)}; nothing changed" unless in_progress

    abort_copies(generation, remote)
    generation
  end

  private

    def locate(local, remote)
      POSITIONS.each do |position, (at_local, at_remote)|
        generation = local.generation - at_local.last
        return [position, generation] if at?(local, at_local, generation) && at?(remote, at_remote, generation)
      end

      raise Unresumable, "Timekeeping re-cutover: no step of the re-cutover leaves #{describe(local, remote)}; nothing changed"
    end

    def at?(copy, (owner, state, offset), generation)
      copy.owner == owner && copy.state == state && copy.generation == generation + offset
    end

    def describe(local, remote)
      "this application at #{TimekeepingReservations::Handoff.summary(local)}, " \
        "Timekeeping at #{TimekeepingReservations::Handoff.summary(remote)}"
    end

    # Steps

    def close_local(generation)
      remember(nil)
      Timekeeping::HandoffFence.call(:close, generation: generation - 1)
      remember(Timekeeping::FinancialSnapshot.process)
    end

    def close_remote(generation) = @client.run_step(:close, generation: generation - 1)

    def freeze_local(generation)
      Timekeeping::HandoffSettle.call(generation:)
      Timekeeping::HandoffFence.call(:freeze, generation:)
    end

    def freeze_remote(generation) = @client.run_step(:freeze, generation:)

    def transfer(generation)
      remember(Timekeeping::FinancialSnapshot.process) unless @financial_snapshot
      wait_for_drain!
      checkpoint = Timekeeping::LocalCheckpoint.take(generation:)
      @client.load_recutover_checkpoint(checkpoint)
      reconcile(checkpoint)
    rescue Timekeeping::LocalCheckpoint::Unsettled => error
      abort_handoff(generation, :checkpoint, error)
    rescue Timekeeping::RecutoverReconcile::Differs => error
      abort_handoff(generation, :reconcile_local, error)
    rescue CountsDiffer => error
      abort_handoff(generation, :reconcile, error)
    rescue Timekeeping::HandoffClient::Problem => error
      raise unless REFUSED.key?(error.type)

      abort_handoff(generation, REFUSED.fetch(error.type), error)
    end

    def flip_remote(generation) = @client.run_step(:flip, generation:)

    def flip_local(generation) = Timekeeping::HandoffFence.call(:flip, generation:)

    # Timekeeping's reconcile, then this side's; both counted each part of
    # the one checkpoint carried, so their answers must agree.
    def reconcile(checkpoint)
      remote = @client.reconcile_recutover_checkpoint(checkpoint)
      local = Timekeeping::RecutoverReconcile.call(checkpoint, financial_snapshot: @financial_snapshot)
      raise CountsDiffer.new(remote, local) unless remote.to_h == local.to_h

      local
    end

    # Keeps the financial snapshot the run took, and records it in the
    # journal.
    def remember(financial_snapshot)
      @financial_snapshot = financial_snapshot
      @journal.record(resume)
    end

    # §10.5 step 3's "drain the outbox into the projection": every snapshot
    # the `monolith` owner wrote into the prepared application's outbox,
    # through the final position freeze left, has reached timesheet_entries.
    # The local relay delivers it on its own worker; frozen, nothing adds to
    # the outbox, so this only waits for it.
    def wait_for_drain!
      deadline = @drain.clock.call + @drain.timeout

      until (undelivered = Timekeeping::OutboxSnapshot.undelivered.count).zero?
        if @drain.clock.call >= deadline
          raise DrainTimeout,
            "Timekeeping re-cutover: #{undelivered} snapshots undelivered after #{@drain.timeout} s; " \
            "both copies stay frozen, run again to resume"
        end

        @drain.pause.call(POLL_INTERVAL)
      end
    end

    def abort_handoff(generation, step, error)
      abort_copies(generation, @client.status.copy)
      raise Aborted.new(step, error.lists, error.message)
    end

    def abort_copies(generation, remote)
      @client.run_step(:abort, generation:) if remote.generation == generation && FENCED.include?(remote.state)
      Timekeeping::HandoffFence.call(:abort, generation:)
      log("aborted at generation #{generation}")
    end

    def log(message) = @logger.info("Timekeeping re-cutover: #{message}")
end
