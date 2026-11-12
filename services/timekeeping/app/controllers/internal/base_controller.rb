# frozen_string_literal: true

# What every internal API endpoint shares (docs/architecture/timekeeping-soa.md
# §5.1, §6.1): the caller's user token, the headers its contract requires,
# its input checked against the contract, and every refusal answered as a
# contract problem. An endpoint names its contract in CONTRACT.
class Internal::BaseController < ActionController::API
  before_action :authenticate!, :require_headers!

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
      missing = Contracts.document(self.class::CONTRACT).dig("x-headers", "every")
        .reject { |name| request.headers[name].present? }
      refuse!("invalid-request", 400, "missing headers: #{missing.join(', ')}") if missing.any?
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
