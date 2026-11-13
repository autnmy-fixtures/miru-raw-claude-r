# frozen_string_literal: true

# Timekeeping's copy of the ownership record (docs/architecture/timekeeping-soa.md
# §10.1): which owner holds entries, under which generation, and whether
# admission is open. HandoffFence changes it; everything else only reads it.
#
# No row means no handoff has ever run here. The column defaults are the
# initial legacy state, so .current returns them unsaved. The only other
# insert is .locked_row, which needs a row to lock and writes exactly those
# defaults.
class Ownership < ApplicationRecord
  SINGLETON_ID = 1

  # Raised by .admit! when this copy refuses a mutating call. Nothing was
  # written; `problem` is the contract's answer (§5.1).
  class Refused < Problem::Raised; end

  # Why a mutating call is refused; the first that holds wins (§5.1, §9.3).
  #
  # - stale-generation: the call carries another generation, or carries this
  #   one while Timekeeping does not own entries (before the first cutover,
  #   or after a rollback). The gateway re-reads ownership and retries against
  #   the current owner only if the command was never admitted.
  # - ownership-moving: a handoff has admission closed or frozen at this
  #   generation. Retryable once it finishes (§10.1).
  Refusal = Data.define(:slug, :status, :retryable, :refuses)

  REFUSALS = [
    Refusal.new(slug: "stale-generation", status: 409, retryable: false,
      refuses: ->(ownership, carried) { carried != ownership.generation || !ownership.owner_timekeeping? }),
    Refusal.new(slug: "ownership-moving", status: 503, retryable: true,
      refuses: ->(ownership, _carried) { !ownership.state_open? })
  ].freeze

  attribute :id, default: SINGLETON_ID

  enum :owner, { legacy: "legacy", timekeeping: "timekeeping", monolith: "monolith" }, prefix: true
  enum :state, { open: "open", closed: "closed", frozen: "frozen" }, prefix: true

  def self.current
    find_by(id: SINGLETON_ID) || new
  end

  # Admission for one mutating call carrying `generation` (its
  # X-Ownership-Generation, §5.1): the record read FOR SHARE, which the
  # caller's transaction then holds until it commits or rolls back, or
  # Refused. Raising the generation takes the row exclusively, so it waits for
  # every call admitted this way, and a call that arrives while it is held
  # waits and then reads the raised record. Must run inside the call's own
  # write transaction.
  #
  # `settle: true` is for the reservation API's commit and abort only: it
  # also admits a call the settle step's exception covers (#settling?). The
  # caller then answers only for an operation Timekeeping registered.
  def self.admit!(generation, settle: false)
    lock_shared!.tap do |ownership|
      next if settle && ownership.settling?(generation)

      refusal = REFUSALS.find { |candidate| candidate.refuses.call(ownership, generation) }
      raise Refused, refusal_problem(refusal, ownership, generation) if refusal
    end
  end

  # Refuses as `slug`, one of REFUSALS, for a call carrying `generation`
  # that admission let through but its endpoint will not answer.
  def self.refuse!(slug, ownership, generation)
    raise Refused, refusal_problem(REFUSALS.find { |refusal| refusal.slug == slug }, ownership, generation)
  end

  def self.lock_shared!
    locked_row("FOR SHARE")
  end

  # The handoff's lock (§10.5): the record read FOR UPDATE, which waits for
  # every call holding it FOR SHARE. Only HandoffFence takes it.
  def self.lock_exclusive!
    locked_row("FOR UPDATE")
  end

  # A database where no handoff has run has no row to lock, so the initial
  # row is written first; concurrent callers race safely on ON CONFLICT DO
  # NOTHING and all lock the one row.
  def self.locked_row(clause)
    insert({ id: SINGLETON_ID }) unless exists?(id: SINGLETON_ID)
    lock(clause).find(SINGLETON_ID)
  end
  private_class_method :locked_row

  def self.refusal_problem(refusal, ownership, generation)
    Problem.new(
      slug: refusal.slug, status: refusal.status, retryable: refusal.retryable,
      detail: "X-Ownership-Generation #{generation} refused: Timekeeping holds #{ownership.summary}"
    )
  end
  private_class_method :refusal_problem

  # The settle step's exception (§10.5 step 2): "During this step only, the
  # outgoing owner still applies a commit or abort that carries the old
  # generation, and only for an operation it registered." True for a call
  # carrying an older generation while Timekeeping is the outgoing owner of a
  # handoff whose admission is closed: after close and before freeze, which
  # is when settle runs. Freeze ends it. So does abort, which reopens
  # admission at the raised generation and leaves the old one stale for good.
  def settling?(carried)
    owner_timekeeping? && state_closed? && carried < generation
  end

  def summary = TimekeepingReservations::Handoff.summary(self)
end
