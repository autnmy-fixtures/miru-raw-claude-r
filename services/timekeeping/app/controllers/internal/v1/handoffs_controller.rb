# frozen_string_literal: true

# The handoff API (handoff_api.json; docs/architecture/timekeeping-soa.md
# §10.1, §10.5): how the handoff tool, run from the existing application,
# reaches Timekeeping's side of the procedure. The two applications share no
# database (§11.2), so the tool moves Timekeeping's copy of the ownership
# record and carries the checkpoint here.
#
#   GET  /internal/v1/handoff                       the copy, and where the relay stands
#   POST /internal/v1/handoff/steps/{step}          HandoffFence: close, freeze, flip, abort
#   POST /internal/v1/handoff/checkpoint            CheckpointLoad (§10.5 steps 4 and 5)
#   POST /internal/v1/handoff/checkpoint/reconcile  CheckpointReconcile (step 6)
#
# Only the handoff tool's service token is accepted, never a user token. The
# calls are not admitted writes: each service guards itself by the step the
# copy is at, so a replay is refused out of step and changes nothing, and no
# Idempotency-Key is needed. The generation travels in X-Ownership-Generation
# as on every mutating call (§5.1), and must be the body's.
#
# A checkpoint body is read exactly as sent (JSON.parse of the raw body), not
# through Rails' parameter parsing, which would rewrite a [null] inside an
# entry's metadata: the load copies values as carried (§8 item 1).
class Internal::V1::HandoffsController < Internal::BaseController
  CONTRACT = :handoff_api

  # Each service's refusal, answered as its problem. Nothing changed.
  rescue_from TimekeepingReservations::Handoff::OutOfStep do |error|
    answer_problem!(Problem.new(slug: "out-of-step", status: 409, detail: error.message))
  end

  # A step's lock waited out its 60 s for the calls already admitted
  # (§10.1). The record is unchanged; the tool may run the step again.
  rescue_from ActiveRecord::LockWaitTimeout do
    answer_problem!(Problem.new(
      slug: "drain-timeout", status: 503, retryable: true,
      detail: "Timekeeping handoff: calls already admitted did not finish within the step's lock timeout; nothing changed"
    ))
  end

  rescue_from CheckpointLoad::AlreadyLoaded do |error|
    answer_problem!(Problem.new(slug: "already-loaded", status: 409, detail: error.message))
  end

  rescue_from CheckpointLoad::Refused do |error|
    answer_problem!(Problem.new(slug: "checkpoint-refused", status: 422, detail: error.message, lists: error.lists))
  end

  rescue_from CheckpointReconcile::Differs do |error|
    answer_problem!(Problem.new(slug: "checkpoint-differs", status: 409, detail: error.message, lists: error.lists))
  end

  def show
    render json: status_of(Ownership.current)
  end

  def step
    generation = carried_generation!(contract_input!("#/$defs/step_request", body!))
    render json: status_of(HandoffFence.call(params[:step].to_sym, generation:))
  end

  def load_checkpoint
    checkpoint = checkpoint!
    loaded = CheckpointLoad.call(**checkpoint, request_id: request.headers["X-Request-Id"])
    render json: { "entries" => loaded.entries, "reservations" => loaded.reservations }
  end

  def reconcile_checkpoint
    reconciled = CheckpointReconcile.call(**checkpoint!)
    render json: { "entries" => reconciled.entries, "reservations" => reconciled.reservations }
  end

  private

    def authenticate!
      @claims = HandoffToken.verify(request.authorization)
      refuse!("unauthenticated", 401, "a valid Timekeeping handoff token is required") unless @claims
    end

    def body!
      JSON.parse(request.raw_post.presence || "{}")
    rescue JSON::ParserError => e
      refuse!("invalid-request", 400, "the body is not JSON: #{e.message}")
    end

    def carried_generation!(input)
      carried_generation.tap do |generation|
        refuse!("invalid-request", 400, "body generation differs from X-Ownership-Generation") unless input.fetch("generation") == generation
      end
    end

    # The checkpoint as the services take it: its generation, its entries as
    # carried, and its reservations as TimekeepingReservations::Reservation
    # values.
    def checkpoint!
      input = contract_input!("#/$defs/checkpoint", body!)
      {
        generation: carried_generation!(input),
        entries: input.fetch("entries"),
        reservations: input.fetch("reservations").map { |reservation| reservation_of(reservation) }
      }
    end

    def reservation_of(reservation)
      TimekeepingReservations::Reservation.new(
        **reservation.symbolize_keys.merge(state: reservation.fetch("state").to_sym, disposition: reservation.fetch("disposition").to_sym)
      )
    end

    def status_of(ownership)
      {
        "ownership" => ownership.slice(:generation, :owner, :state),
        "outbox" => { "latest_position" => OutboxSnapshot.maximum(:id), "undelivered" => OutboxSnapshot.undelivered.count }
      }
    end

    def answer_problem!(problem)
      render json: problem, status: problem.status, content_type: "application/problem+json"
    end
end
