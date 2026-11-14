# frozen_string_literal: true

# Timekeeping's side of the handoff procedure (docs/architecture/
# timekeeping-soa.md §10.1, §10.5), over the handoff API (handoff_api.json),
# for the handoff tool run from this application. The two applications share
# no database (§11.2), so the tool moves Timekeeping's copy of the ownership
# record and carries the checkpoint to it through this client:
#
#   #status                Timekeeping's copy of the record, and where its
#                          relay stands (the drain of §10.5 step 3)
#   #run_step              close, freeze, flip or abort on that copy
#   #load_checkpoint       §10.5 steps 4 and 5 in Timekeeping
#   #reconcile_checkpoint  step 6 in Timekeeping
#
# Every call carries the handoff tool's service token (Timekeeping::
# HandoffToken), never a user token, and every POST the generation it expects
# in X-Ownership-Generation, which is also the body's (§5.1). A request the
# contract cannot carry raises Invalid and is never sent.
#
# This client never retries and sends no Idempotency-Key. Each of
# Timekeeping's steps guards itself by where the copy is: a replayed step is
# refused out-of-step, a second load already-loaded, and reconcile writes
# nothing. So after Unavailable, whether the step ran is unknown: the tool
# reads #status and runs again only the step that did not commit.
#
# A step may wait up to its 60 s lock timeout for the calls Timekeeping
# already admitted (§10.1), and a load copies the whole dataset, so a call
# here may take longer than the 2 s of the request path (§9.4).
class Timekeeping::HandoffClient < Timekeeping::InternalApi
  CONTRACT = :handoff_api
  TIMEOUT = 90 # seconds: a step's 60 s lock timeout, and a margin
  STEPS = %w[close freeze flip abort].freeze

  # Timekeeping's copy of the ownership record (§10.1).
  Copy = Data.define(:generation, :owner, :state)

  # Where Timekeeping's relay stands (§5.4): the latest outbox position, nil
  # while the outbox is empty, and how many snapshots it has not delivered.
  Outbox = Data.define(:latest_position, :undelivered) do
    # The projection holds everything through the latest position.
    def drained? = undelivered.zero?
  end

  Status = Data.define(:copy, :outbox)

  # How many entries and reservations a checkpoint carried, loaded or
  # reconciled.
  Receipt = Data.define(:entries, :reservations)

  # Timekeeping could not be reached, timed out, or answered a 5xx that is not
  # a problem of the contract. Whether a step ran is not known.
  class Unavailable < Timekeeping::InternalApi::Error; end

  # The request breaks the handoff API contract, so it was not sent.
  class Invalid < Timekeeping::InternalApi::Error
    attr_reader :errors

    def initialize(operation, errors)
      @errors = errors
      super("Timekeeping #{operation}: #{errors.join('; ')}")
    end
  end

  def status = status_of(request(:read_handoff))

  # Runs `step` on Timekeeping's copy, expected at `generation` (the
  # generation before close raises it, the raised one after), and answers the
  # copy as the step left it.
  def run_step(step, generation:)
    raise Invalid.new(:run_step, ["#{step} is not a step of #{STEPS.join(', ')}"]) unless STEPS.include?(step.to_s)

    status_of(request(:run_step, { "generation" => generation }, generation:, step:))
  end

  # The checkpoint is anything with generation, entries in the contract's
  # full-entry form, and reservations as TimekeepingReservations::Reservation
  # values: what Timekeeping::LegacyCheckpoint takes. `request_id` names the
  # handoff in the outbox snapshots the load writes.
  def load_checkpoint(checkpoint, request_id: SecureRandom.uuid)
    receipt_of(request(:load_checkpoint, checkpoint_body(checkpoint), generation: checkpoint.generation, request_id:))
  end

  # Writes nothing in Timekeeping. A difference raises Problem
  # checkpoint-differs, whose `lists` gives what each failed check found.
  def reconcile_checkpoint(checkpoint)
    receipt_of(request(:reconcile_checkpoint, checkpoint_body(checkpoint), generation: checkpoint.generation))
  end

  private

    def request(name, body = nil, generation: nil, request_id: SecureRandom.uuid, **path_params)
      operation = contract_operation(name)
      errors = body ? Timekeeping::Contracts.errors(CONTRACT, operation.fetch("request"), body) : []
      raise Invalid.new(name, errors) if errors.any?

      response = http.run_request(
        operation.fetch("method").downcase.to_sym, path(operation, path_params), body && JSON.generate(body),
        headers(generation, request_id)
      )
      answered(name, operation, response)
    rescue Faraday::Error => error
      raise Unavailable, "Timekeeping #{name}: #{error.message}"
    end

    def answered(name, operation, response)
      answer(operation, response)
    rescue Timekeeping::InternalApi::ContractViolation
      raise Unavailable, "Timekeeping #{name}: HTTP #{response.status}" if response.status >= 500

      raise
    end

    def headers(generation, request_id)
      {
        "Authorization" => "Bearer #{Timekeeping::HandoffToken.sign(key: @token_key, now: @clock.call)}",
        "X-Request-Id" => request_id
      }.merge(generation.nil? ? {} : { "X-Ownership-Generation" => generation.to_s, "Content-Type" => "application/json" })
    end

    def path(operation, path_params)
      operation.fetch("path").gsub(/\{(\w+)\}/) { path_params.fetch(Regexp.last_match(1).to_sym).to_s }
    end

    def checkpoint_body(checkpoint)
      {
        "generation" => checkpoint.generation,
        "entries" => checkpoint.entries,
        "reservations" => checkpoint.reservations.map do |reservation|
          reservation.to_h.transform_keys(&:to_s).merge("state" => reservation.state.to_s, "disposition" => reservation.disposition.to_s)
        end
      }
    end

    def status_of(body)
      Status.new(
        copy: Copy.new(**body.fetch("ownership").symbolize_keys),
        outbox: Outbox.new(**body.fetch("outbox").symbolize_keys)
      )
    end

    def receipt_of(body) = Receipt.new(**body.symbolize_keys)
end
