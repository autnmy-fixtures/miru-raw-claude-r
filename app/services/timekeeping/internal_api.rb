# frozen_string_literal: true

# What every client of Timekeeping's internal API shares
# (docs/architecture/timekeeping-soa.md §5.1): its configuration, its errors,
# the system-actor token (§6.1), the 2 s timeout (§9.2 step 2, §9.4), and
# reading an answer against the client's contract. A client inherits from
# this class and names its contract in CONTRACT; one whose calls may wait
# longer than 2 s by design names its own TIMEOUT.
class Timekeeping::InternalApi
  TIMEOUT = 2 # seconds, §9.2 step 2 and §9.4
  PROBLEM = "common.json#/$defs/problem"

  class Error < StandardError; end

  # Timekeeping is not configured here: no URL or no shared token key.
  class NotConfigured < Error; end

  # Timekeeping answered application/problem+json (§5.1), read from the body
  # the contract's problem definition allows.
  class Problem < Error
    attr_reader :status, :type, :retryable, :detail, :refused, :errors, :lists

    # `type` is the stable slug, without the problem base URI. `refused`
    # lists, for reservation-refused only, every entry prepare refused and why
    # (F1, L8), as the shared rule's Refusal. `errors` is, for
    # validation-failed only, the model's errors by attribute. `lists` is, for
    # checkpoint-refused and checkpoint-differs only, each check that failed
    # and the entry ids or receipt identifiers it found (§10.4).
    def initialize(body)
      @status, @retryable, @detail = body.fetch("status"), body.fetch("retryable"), body["detail"]
      @type = body.fetch("type").delete_prefix(Timekeeping::Contracts::PROBLEM_BASE)
      @errors = body.fetch("errors", {})
      @lists = body.fetch("lists", {})
      @refused = body.fetch("refused", []).map do |refusal|
        TimekeepingReservations::Refusal.new(entry_id: refusal.fetch("entry_id"), reason: refusal.fetch("reason").to_sym)
      end
      super(["#{status} #{type}", detail].compact.join(": "))
    end
  end

  # The answer is not one the contract allows.
  class ContractViolation < Error; end

  def initialize(url: config.url, token_key: config.token_key, clock: -> { Time.current })
    raise NotConfigured, "TIMEKEEPING_URL is not set" if url.blank?
    raise NotConfigured, "TIMEKEEPING_TOKEN_KEY is not set" if token_key.blank?

    @url, @token_key, @clock = url, token_key, clock
  end

  private

    def config = Rails.configuration.x.timekeeping

    def contract_operation(name)
      Timekeeping::Contracts.document(self.class::CONTRACT).fetch("x-operations").fetch(name.to_s)
    end

    # The headers every call carries (§5.1): a system-actor token for the
    # company (§6.1) and the request id it names.
    def identity_headers(company:, writer:)
      token_headers(Timekeeping::UserToken.system_claims(company:, writer:, request_id: SecureRandom.uuid))
    end

    # The token for the claims, and the request id they name.
    def token_headers(claims)
      {
        "Authorization" => "Bearer #{Timekeeping::UserToken.sign(claims, key: @token_key, now: @clock.call)}",
        "X-Request-Id" => claims.fetch("request_id")
      }
    end

    # The body of an answer the contract allows for the operation. A problem
    # Timekeeping answered raises Problem; anything else raises
    # ContractViolation.
    def answer(operation, response)
      body = parse(response)
      expected = operation.dig("responses", response.status.to_s)
      return body if expected && conforms?(expected, body)
      raise Problem.new(body) if response.status >= 400 && conforms?(PROBLEM, body)

      raise ContractViolation, "HTTP #{response.status} is not an answer of the #{self.class::CONTRACT} contract: #{response.body.to_s.truncate(200)}"
    end

    def parse(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end

    def conforms?(pointer, body)
      body.is_a?(Hash) && Timekeeping::Contracts.errors(self.class::CONTRACT, pointer, body).empty?
    end

    def http
      @http ||= Faraday.new(url: @url, request: { timeout: self.class::TIMEOUT, open_timeout: TIMEOUT })
    end
end
