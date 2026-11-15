# frozen_string_literal: true

# The handoff tool for the rollback, timekeeping -> monolith
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5). It runs the
# procedure's steps in order on both copies of the ownership record (§10.1):
# this application's, through Timekeeping::HandoffFence, and Timekeeping's,
# through Timekeeping::HandoffClient, because the two applications share no
# database (§11.2). The incoming owner is the prepared application here
# (§10.5 "Rollback target"), so the checkpoint comes out of Timekeeping and is
# loaded and reconciled on this side.
#
#   close_local    1. close admission here, where every write enters (the
#                     gateway and the billing-write fence), and take the
#                     financial snapshot once the close has drained every
#                     billing write already admitted (§10.1, §13 item 2)
#   close_remote      close Timekeeping's copy at the same generation, which
#                     refuses every command still carrying the old one
#   freeze_local   2. settle every registered invoice operation
#                     (Timekeeping::HandoffSettle): Timekeeping, the outgoing
#                     owner, still applies their commit or abort under the old
#                     generation while its copy is closed; 3. then freeze here
#   freeze_remote     freeze Timekeeping's copy: no write changes it any more
#   transfer          wait for Timekeeping's relay to deliver its outbox into
#                     timesheet_entries (§10.5 step 3); 4. take the checkpoint
#                     out of Timekeeping (HandoffClient#take_checkpoint) and
#                     load it into the prepared application
#                     (Timekeeping::CheckpointLoad), 5. which sets its id
#                     sequences; 6. reconcile it
#                     (Timekeeping::RollbackReconcile)
#   flip_local     7. flip this copy, the incoming owner, first
#   flip_remote       then Timekeeping's
#
# The incoming owner flips first, as in the first cutover. Between the two
# flips Timekeeping's copy is still frozen and refuses every write, and the
# gateway already sends every write to the `monolith` owner here, so no write
# reaches an owner that has handed its entries over.
#
# It resumes. Every run starts by reading both copies, and where they stand
# names the one step to run next (POSITIONS); a step that committed is never
# run again. Repeating `transfer` is safe: the take is a read of a frozen
# Timekeeping, so it carries the same checkpoint each time; a load that
# already ran answers AlreadyLoaded and the run goes on to reconcile, which
# writes nothing. A resumed transfer therefore reconciles what the earlier run
# loaded against Timekeeping as it stands, not against a copy kept since. A
# pair of copies that is no position of this rollback is Unresumable, and
# nothing is changed.
#
# What a run does on failure:
#
# - A refusal that a retry cannot change aborts the handoff on both copies
#   (§10.5 step 6) and raises Aborted with what was found: an operation
#   settle left unresolved in Timekeeping (checkpoint-unsettled, at the take),
#   a checkpoint the prepared application refused to load, or a reconcile
#   difference. The raised generation stays, so commands admitted under the
#   old one stay refused.
# - Anything else leaves both copies fenced where they are and raises:
#   Timekeeping unreachable (HandoffClient::Unavailable), a step whose lock
#   waited out the writes already admitted (ActiveRecord::LockWaitTimeout, or
#   Timekeeping's drain-timeout), a settle that could not deliver every
#   outcome (HandoffFence::Unsettled), or a relay that did not drain in time
#   (DrainTimeout). Run again to resume, or #abort! to reopen admission.
#
# An abort reopens both copies under Timekeeping and leaves the prepared
# application's tables as they are. If the load had run, they still hold that
# checkpoint, and a later rollback's load answers AlreadyLoaded: its reconcile
# then compares them with Timekeeping as it stands and aborts on any write
# Timekeeping took since. It never flips onto them unreconciled.
#
# The financial snapshot is the "before" of the money check. A run that
# starts at close_local takes it; a resumed run is given the one taken before
# the interruption (its journal's), or takes it itself. Both are taken while
# admission is closed, and no billing write is admitted then (§10.1), so
# either is the state the handoff must leave unchanged. The journal has the
# first cutover's interface (Timekeeping::FirstCutover::MemoryJournal by
# default, Timekeeping::RollbackJournal for a file that outlives the process):
# it is told an empty Resume as a handoff starts, so nothing an earlier
# handoff took is resumed into this one, then the snapshot as soon as it is
# taken. It holds no checkpoint, since the take can always be asked again.
class Timekeeping::Rollback
  # The run cannot go on from where it stands: both copies are where no step
  # of this rollback leaves them. Nothing was changed.
  class Unresumable < StandardError; end

  # Timekeeping's relay had not delivered its outbox into timesheet_entries
  # when the wait ran out. Both copies stay frozen; run again to resume.
  class DrainTimeout < StandardError; end

  # The handoff was aborted on both copies. `step` names what refused, and
  # `lists` what it found, by check (§10.4).
  class Aborted < StandardError
    attr_reader :step, :lists

    def initialize(step, lists, reason)
      @step, @lists = step, lists
      super("Timekeeping rollback aborted at #{step}: #{reason}")
    end
  end

  # The generation the handoff raised to, and what the reconcile counted
  # (Timekeeping::RollbackReconcile::Reconciled), nil when the run resumed
  # after the reconcile had already passed.
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

  STEPS = %i[close_local close_remote freeze_local freeze_remote transfer flip_local flip_remote].freeze

  # Where the rollback at generation g stands, as (owner, state, generation -
  # g) of this application's copy and Timekeeping's, and the step that runs
  # next. A step that is not listed is never where a run stops: transfer runs
  # again until flip_local commits.
  POSITIONS = {
    close_local: [["timekeeping", "open", -1], ["timekeeping", "open", -1]],
    close_remote: [["timekeeping", "closed", 0], ["timekeeping", "open", -1]],
    freeze_local: [["timekeeping", "closed", 0], ["timekeeping", "closed", 0]],
    freeze_remote: [["timekeeping", "frozen", 0], ["timekeeping", "closed", 0]],
    transfer: [["timekeeping", "frozen", 0], ["timekeeping", "frozen", 0]],
    flip_remote: [["monolith", "open", 0], ["timekeeping", "frozen", 0]],
    done: [["monolith", "open", 0], ["monolith", "open", 0]]
  }.freeze

  # Timekeeping's refusal of the take that no retry changes: frozen, nothing
  # resolves the operation settle left (handoff_api.json take_checkpoint).
  UNSETTLED = "checkpoint-unsettled"

  # The states of a copy a handoff has fenced, which abort reopens.
  FENCED = Timekeeping::FirstCutover::FENCED

  POLL_INTERVAL = Timekeeping::FirstCutover::POLL_INTERVAL

  attr_reader :financial_snapshot

  # `journal` holds what an interrupted run took: the run starts from its
  # `resume`, and tells it `record(resume)` each time it takes something.
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
  # first, at the generation it raised to, both still under Timekeeping.
  # Unresumable when no rollback is in progress, or once a copy has flipped:
  # past the flip the handoff only goes forward. Answers that generation.
  def abort!
    local, remote = Timekeeping::Ownership.current, @client.status.copy
    generation = local.generation
    in_progress = local.owner == "timekeeping" && FENCED.include?(local.state) && remote.owner == "timekeeping"
    raise Unresumable, "Timekeeping rollback: nothing to abort, #{describe(local, remote)}; nothing changed" unless in_progress

    abort_copies(generation, remote)
    generation
  end

  private

    def locate(local, remote)
      POSITIONS.each do |position, (at_local, at_remote)|
        generation = local.generation - at_local.last
        return [position, generation] if at?(local, at_local, generation) && at?(remote, at_remote, generation)
      end

      raise Unresumable, "Timekeeping rollback: no step of the rollback leaves #{describe(local, remote)}; nothing changed"
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
      checkpoint = @client.take_checkpoint(generation:)
      load_checkpoint(checkpoint)
      Timekeeping::RollbackReconcile.call(checkpoint, financial_snapshot: @financial_snapshot)
    rescue Timekeeping::CheckpointLoad::Refused => error
      abort_handoff(generation, :load, error)
    rescue Timekeeping::RollbackReconcile::Differs => error
      abort_handoff(generation, :reconcile, error)
    rescue Timekeeping::HandoffClient::Problem => error
      raise unless error.type == UNSETTLED

      abort_handoff(generation, :checkpoint, error)
    end

    def flip_local(generation) = Timekeeping::HandoffFence.call(:flip, generation:)

    def flip_remote(generation) = @client.run_step(:flip, generation:)

    # Keeps the financial snapshot the run took, and records it in the
    # journal.
    def remember(financial_snapshot)
      @financial_snapshot = financial_snapshot
      @journal.record(resume)
    end

    # A load that already ran (a resumed run) goes on to reconcile it.
    def load_checkpoint(checkpoint)
      Timekeeping::CheckpointLoad.call(checkpoint)
    rescue Timekeeping::CheckpointLoad::AlreadyLoaded
      log("load at generation #{checkpoint.generation}: already loaded, reconciling it")
    end

    # §10.5 step 3's "drain the outbox into the projection": every snapshot
    # Timekeeping wrote, through the final position freeze left, has reached
    # timesheet_entries.
    def wait_for_drain!
      deadline = @drain.clock.call + @drain.timeout

      until (outbox = @client.status.outbox).drained?
        if @drain.clock.call >= deadline
          raise DrainTimeout,
            "Timekeeping rollback: #{outbox.undelivered} snapshots undelivered after #{@drain.timeout} s; " \
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

    def log(message) = @logger.info("Timekeeping rollback: #{message}")
end
