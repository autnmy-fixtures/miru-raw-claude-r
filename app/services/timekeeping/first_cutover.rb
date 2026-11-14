# frozen_string_literal: true

# The handoff tool for the first cutover, legacy -> timekeeping
# (docs/architecture/timekeeping-soa.md §10.2 step 5, §10.5). It runs the
# procedure's steps in order on both copies of the ownership record (§10.1):
# this application's, through Timekeeping::HandoffFence, and Timekeeping's,
# through Timekeeping::HandoffClient, because the two applications share no
# database (§11.2).
#
#   close_local    1. close admission here (the legacy owner's traffic), and
#                     take the financial snapshot once the close has drained
#                     every billing write already admitted (§10.1, §13 item 2)
#   close_remote      close Timekeeping's copy at the same generation
#   freeze_local   2. settle every registered invoice operation
#                     (Timekeeping::HandoffSettle), 3. then freeze here
#   freeze_remote     freeze Timekeeping's copy
#   transfer       4. take the checkpoint from the legacy owner
#                     (Timekeeping::LegacyCheckpoint) and load it into
#                     Timekeeping, 5. which sets its id sequence; wait for its
#                     relay to deliver every snapshot the load wrote into
#                     timesheet_entries; 6. reconcile on both sides
#                     (Timekeeping's, then Timekeeping::CheckpointReconcile)
#   flip_remote    7. flip Timekeeping's copy, the incoming owner, first
#   flip_local        then this one
#
# The incoming owner flips first. Between the two flips this side is still
# frozen and refuses every write as moving (503, retryable), so no write is
# routed to a Timekeeping that does not own entries yet.
#
# It resumes. Every run starts by reading both copies, and where they stand
# names the one step to run next (POSITIONS); a step that committed is never
# run again. A load that already ran answers already-loaded and the run goes
# on to reconcile, which writes nothing, so repeating `transfer` is safe. A
# pair of copies that is no position of this cutover is Unresumable, and
# nothing is changed.
#
# The checkpoint is taken once (§10.5 step 4: "one frozen, verified
# checkpoint"), and a resumed transfer reuses it (the journal's). It cannot be
# taken again once the load has run: the relay then writes Timekeeping's
# snapshots into timesheet_entries, the table the legacy checkpoint is read
# from, so a second one would carry Timekeeping's versions and prove nothing
# about the first. Timekeeping's outbox shows whether the load ran: under the
# legacy owner nothing else writes it. A run that must reconcile a load it
# holds no checkpoint for is Unresumable; resume it with the checkpoint
# taken before the load, or #abort!.
#
# What a run does on failure:
#
# - A refusal that a retry cannot change aborts the handoff on both copies
#   (§10.5 step 6) and raises Aborted with what was found: a pre-flight item
#   with no recorded disposition, a checkpoint Timekeeping refused, or a
#   reconcile difference on either side. The raised generation stays, so
#   commands admitted under the old one stay refused.
# - Anything else leaves both copies fenced where they are and raises:
#   Timekeeping unreachable (HandoffClient::Unavailable), a step whose lock
#   waited out the writes already admitted (ActiveRecord::LockWaitTimeout, or
#   Timekeeping's drain-timeout), a settle that could not deliver every
#   outcome (HandoffFence::Unsettled), or a relay that did not drain in time
#   (DrainTimeout). Run again to resume, or #abort! to reopen admission.
#
# The financial snapshot is the "before" of the money check. A run that
# starts at close_local takes it; a resumed run is given the one taken before
# the interruption (the journal's; the snapshot is JSON-safe), or takes it
# itself.
# Both are taken while admission is closed, and no billing write is admitted
# then (§10.1), so either is the state the handoff must leave unchanged.
#
# What a run took is kept in its journal, which a later run is given to
# resume from. A run starts from the journal's #resume, and records its own
# #resume in it as soon as it takes the financial snapshot, and again as soon
# as it takes the checkpoint, before the load, so a run that stops at any
# later point leaves the checkpoint the load carried. A run that starts a
# handoff (close_local) first records an empty resume, so nothing an earlier
# handoff took is resumed into this one. MemoryJournal, the default, keeps it
# within one process; Timekeeping::FirstCutoverJournal keeps it in a file,
# across processes (the timekeeping:first_cutover task).
#
# Rollback and re-cutover take this shape in the other direction once the
# prepared application's entry store exists; under any owner but legacy this
# tool finds no position and changes nothing.
class Timekeeping::FirstCutover
  # The run cannot go on from where it stands: both copies are where no step
  # of this cutover leaves them, or the checkpoint a resumed transfer needs
  # is not the one given. Nothing was changed.
  class Unresumable < StandardError; end

  # Timekeeping's relay had not delivered every snapshot the load wrote when
  # the wait ran out. Both copies stay frozen; run again to resume.
  class DrainTimeout < StandardError; end

  # The handoff was aborted on both copies. `step` names what refused, and
  # `lists` what it found, by check (§10.4).
  class Aborted < StandardError
    attr_reader :step, :lists

    def initialize(step, lists, reason)
      @step, @lists = step, lists
      super("Timekeeping first cutover aborted at #{step}: #{reason}")
    end
  end

  # The generation the handoff raised to, and how many entries and
  # reservations both sides reconciled. Those are nil when the run resumed
  # after the reconcile had already passed.
  Result = Data.define(:generation, :entries, :reservations)

  STEPS = %i[close_local close_remote freeze_local freeze_remote transfer flip_remote flip_local].freeze

  # Where the cutover at generation g stands, as (owner, state, generation - g)
  # of this application's copy and Timekeeping's, and the step that runs
  # next. A step that is not listed is never where a run stops: transfer runs
  # again until flip_remote commits.
  POSITIONS = {
    close_local: [["legacy", "open", -1], ["legacy", "open", -1]],
    close_remote: [["legacy", "closed", 0], ["legacy", "open", -1]],
    freeze_local: [["legacy", "closed", 0], ["legacy", "closed", 0]],
    freeze_remote: [["legacy", "frozen", 0], ["legacy", "closed", 0]],
    transfer: [["legacy", "frozen", 0], ["legacy", "frozen", 0]],
    flip_local: [["legacy", "frozen", 0], ["timekeeping", "open", 0]],
    done: [["timekeeping", "open", 0], ["timekeeping", "open", 0]]
  }.freeze

  # Refusals of Timekeeping's that no retry changes (handoff_api.json).
  REFUSED = %w[checkpoint-refused checkpoint-differs].freeze

  # The states of a copy a handoff has fenced, which abort reopens.
  FENCED = %w[closed frozen].freeze

  POLL_INTERVAL = 1 # second

  # How a run waits for Timekeeping's relay to drain: at most `timeout`
  # seconds of `clock` (monotonic), calling `pause` between reads.
  Drain = Data.define(:timeout, :pause, :clock) do
    def initialize(
      timeout: 60, pause: ->(seconds) { sleep(seconds) }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
      super
    end
  end

  # What an interrupted run took, for its resume: the financial snapshot and
  # the checkpoint, each nil until taken.
  Resume = Data.define(:financial_snapshot, :checkpoint) do
    def initialize(financial_snapshot: nil, checkpoint: nil)
      super
    end
  end

  # A journal kept in memory, for runs within one process: what the last run
  # recorded, or the Resume it was built with.
  class MemoryJournal
    attr_reader :resume

    def initialize(resume = Resume.new)
      @resume = resume
    end

    def record(resume)
      @resume = resume
    end
  end

  # `request_id` names this run in the snapshots the load writes (§11.3).
  attr_reader :financial_snapshot, :checkpoint, :request_id

  # `unlocked_link_invoice_ids` is the recorded disposition the checkpoint
  # takes (§10.4): the kept invoices whose unlocked links map to an active
  # reservation with no edit lock. `journal` holds what an interrupted run
  # took: the run starts from its `resume`, and tells it `record(resume)`
  # each time it takes something.
  def initialize(
    client: Timekeeping::HandoffClient.new, unlocked_link_invoice_ids: [], journal: MemoryJournal.new, drain: Drain.new,
    logger: Rails.logger
  )
    @client, @unlocked_link_invoice_ids, @drain, @logger, @journal = client, unlocked_link_invoice_ids, drain, logger, journal
    resume = journal.resume
    @financial_snapshot, @checkpoint = resume.financial_snapshot, resume.checkpoint
    @request_id = SecureRandom.uuid
  end

  # What a later run needs to resume this one.
  def resume = Resume.new(financial_snapshot:, checkpoint:)

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

    Result.new(generation:, entries: reconciled&.entries, reservations: reconciled&.reservations)
  end

  # Reopens admission on every copy the handoff has fenced, Timekeeping's
  # first, at the generation it raised to. Unresumable when no handoff is in
  # progress, or once a copy has flipped: past the flip the handoff only goes
  # forward. Answers that generation.
  def abort!
    local, remote = Timekeeping::Ownership.current, @client.status.copy
    generation = local.generation
    in_progress = local.owner == "legacy" && FENCED.include?(local.state) && remote.owner == "legacy"
    raise Unresumable, "Timekeeping first cutover: nothing to abort, #{describe(local, remote)}; nothing changed" unless in_progress

    abort_copies(generation, remote)
    generation
  end

  private

    def locate(local, remote)
      POSITIONS.each do |position, (at_local, at_remote)|
        generation = local.generation - at_local.last
        return [position, generation] if at?(local, at_local, generation) && at?(remote, at_remote, generation)
      end

      raise Unresumable, "Timekeeping first cutover: no step of the cutover leaves #{describe(local, remote)}; nothing changed"
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
      remember(financial_snapshot: nil, checkpoint: nil)
      Timekeeping::HandoffFence.call(:close, generation: generation - 1)
      remember(financial_snapshot: Timekeeping::FinancialSnapshot.process)
    end

    def close_remote(generation) = @client.run_step(:close, generation: generation - 1)

    def freeze_local(generation)
      Timekeeping::HandoffSettle.call(generation:)
      Timekeeping::HandoffFence.call(:freeze, generation:)
    end

    def freeze_remote(generation) = @client.run_step(:freeze, generation:)

    def transfer(generation)
      checkpoint = checkpoint_for(generation)
      load_checkpoint(checkpoint)
      wait_for_drain!
      @client.reconcile_checkpoint(checkpoint)
      Timekeeping::CheckpointReconcile.call(
        generation:, entries: checkpoint.entries, reservations: checkpoint.reservations, financial_snapshot: @financial_snapshot
      )
    rescue Timekeeping::LegacyCheckpoint::Undisposed => error
      abort_handoff(generation, :checkpoint, error)
    rescue Timekeeping::CheckpointReconcile::Differs => error
      abort_handoff(generation, :reconcile_local, error)
    rescue Timekeeping::HandoffClient::Problem => error
      raise unless REFUSED.include?(error.type)

      abort_handoff(generation, error.type == "checkpoint-refused" ? :load : :reconcile_remote, error)
    end

    def flip_remote(generation) = @client.run_step(:flip, generation:)

    def flip_local(generation) = Timekeeping::HandoffFence.call(:flip, generation:)

    # The checkpoint the transfer carries: the one the run holds, or one it
    # takes, with the financial snapshot if it holds none, and records before
    # anything is loaded.
    def checkpoint_for(generation)
      remember(financial_snapshot: Timekeeping::FinancialSnapshot.process) unless @financial_snapshot
      remember(checkpoint: take_checkpoint(generation)) unless @checkpoint
      return @checkpoint if @checkpoint.generation == generation

      raise Unresumable, "Timekeeping first cutover: the checkpoint given was taken at generation #{@checkpoint.generation}, " \
        "the handoff is at #{generation}; nothing changed"
    end

    # Keeps what the run took, and records it in the journal.
    def remember(**taken)
      @financial_snapshot = taken.fetch(:financial_snapshot, @financial_snapshot)
      @checkpoint = taken.fetch(:checkpoint, @checkpoint)
      @journal.record(resume)
    end

    def take_checkpoint(generation)
      if @client.status.outbox.latest_position
        raise Unresumable,
          "Timekeeping first cutover: the checkpoint is already loaded into Timekeeping at generation #{generation}, " \
          "and its relay has rewritten the legacy rows; resume with the checkpoint taken before the load, or abort; nothing changed"
      end

      Timekeeping::LegacyCheckpoint.take(generation:, unlocked_link_invoice_ids: @unlocked_link_invoice_ids)
    end

    # A load that already ran (a resumed run) goes on to reconcile it.
    def load_checkpoint(checkpoint)
      @client.load_checkpoint(checkpoint, request_id: @request_id)
    rescue Timekeeping::HandoffClient::Problem => error
      raise unless error.type == "already-loaded"

      log("load at generation #{checkpoint.generation}: already loaded, reconciling it")
    end

    # §10.5 step 3's "drain the outbox into the projection": every snapshot
    # Timekeeping wrote has reached timesheet_entries.
    def wait_for_drain!
      deadline = @drain.clock.call + @drain.timeout

      until (outbox = @client.status.outbox).drained?
        if @drain.clock.call >= deadline
          raise DrainTimeout,
            "Timekeeping first cutover: #{outbox.undelivered} snapshots undelivered after #{@drain.timeout} s; " \
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

    def log(message) = @logger.info("Timekeeping first cutover: #{message}")
end
