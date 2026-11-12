# frozen_string_literal: true

# What every internal API endpoint shares (docs/architecture/timekeeping-soa.md
# §5.1, §6.1): the caller's user token, the headers its contract requires,
# its input checked against the contract, every mutating call run as one
# EntryWrite, and every refusal answered as a contract problem. An endpoint
# names its contract in CONTRACT.
#
# Every operation of the contracts that is not a GET is mutating, so it also
# carries the contract's mutating headers: Idempotency-Key and
# X-Ownership-Generation.
class Internal::BaseController < ActionController::API
  before_action :authenticate!, :require_headers!

  # A body is read exactly as sent and checked against the contract, never
  # wrapped under the controller's name first.
  wrap_parameters false

  rescue_from Problem::Raised do |raised|
    render json: raised.problem, status: raised.problem.status, content_type: "application/problem+json"
  end

  private

    # The verified claims of the caller's token (§6.1). Their company scopes
    # every read and write (§6.3).
    attr_reader :claims

    def authenticate!
      @claims = UserToken.verify(request.authorization)
      refuse!("unauthenticated", 401, "a valid Timekeeping user token is required") unless @claims
    end

    def require_headers!
      headers = Contracts.document(self.class::CONTRACT).fetch("x-headers")
      required = headers.fetch("every") + (request.get? ? [] : headers.fetch("mutating"))
      missing = required.reject { |name| request.headers[name].present? }
      refuse!("invalid-request", 400, "missing headers: #{missing.join(', ')}") if missing.any?
    end

    # Runs the change the block makes as one mutating call (EntryWrite) for
    # the contract-checked `input`, and renders what it answers.
    def write!(input, &change)
      call = EntryWrite::Call.new(
        company_id: claims.fetch("company_id"), generation: carried_generation,
        key: request.headers["Idempotency-Key"],
        digest: IdempotencyReceipt.digest(request.request_method, request.path, input)
      )
      status, body = EntryWrite.call(call, &change)
      render json: body, status:
    end

    # The generation the call carries in X-Ownership-Generation (§5.1).
    def carried_generation
      generation = Integer(request.headers["X-Ownership-Generation"], 10, exception: false)
      refuse!("invalid-request", 400, "X-Ownership-Generation is not a generation") unless generation && generation >= 0

      generation
    end

    # `payload` as the contract definition at `pointer` allows it, or
    # invalid-request naming what breaks it.
    def contract_input!(pointer, payload)
      errors = Contracts.errors(self.class::CONTRACT, pointer, payload)
      refuse!("invalid-request", 400, errors.join("; ")) if errors.any?
      payload
    end

    def refuse!(slug, status, detail)
      raise Problem::Raised, Problem.new(slug:, status:, detail:)
    end
end
