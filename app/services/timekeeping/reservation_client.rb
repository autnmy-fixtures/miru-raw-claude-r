# frozen_string_literal: true

# The `timekeeping` owner's side of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3) for the invoice operation
# worker: commit and abort of one ledger intent, over HTTP. Paths, headers and
# bodies come from the reservation API contract, its one source of truth.
#
# Each call carries the intent's own generation and its operation id as the
# Idempotency-Key, so a resend after a lost response is the same request
# (§9.4), and a system-actor token for the intent's company (§6.1). It answers
# the terminal receipt Timekeeping stored. Anything else raises: a problem
# Timekeeping answered, an answer outside the contract, or a transport error
# (Faraday::Error, a 2 s timeout included). The worker's next sweep is the
# retry; this client never retries on its own.
class Timekeeping::ReservationClient
  CONTRACT = :reservation_api
  TIMEOUT = 2 # seconds, §9.2 step 2 and §9.4
  WRITER = "invoice"

  Receipt = Data.define(:status)

  class Error < StandardError; end

  # Timekeeping is not configured here: no URL or no shared token key.
  class NotConfigured < Error; end

  # Timekeeping answered application/problem+json (§5.1).
  class Problem < Error
    attr_reader :status, :type, :retryable

    def initialize(status:, type:, retryable:, detail: nil)
      @status, @type, @retryable = status, type, retryable
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

  def commit(intent) = resolve(:commit, intent)

  def abort(intent) = resolve(:abort, intent)

  private

    def config = Rails.configuration.x.timekeeping

    def resolve(name, intent)
      operation = Timekeeping::Contracts.document(CONTRACT).fetch("x-operations").fetch(name.to_s)
      response = http.post(path(operation, intent), JSON.generate("generation" => intent.generation), headers(intent))
      read(operation, response)
    end

    def path(operation, intent)
      operation.fetch("path")
        .sub("{invoice_id}", intent.invoice_id.to_s)
        .sub("{operation_id}", intent.operation_id)
    end

    def headers(intent)
      request_id = SecureRandom.uuid
      claims = Timekeeping::UserToken.system_claims(company: Company.find(intent.company_id), writer: WRITER, request_id:)
      {
        "Authorization" => "Bearer #{Timekeeping::UserToken.sign(claims, key: @token_key, now: @clock.call)}",
        "X-Request-Id" => request_id,
        "Idempotency-Key" => intent.operation_id,
        "X-Ownership-Generation" => intent.generation.to_s,
        "Content-Type" => "application/json"
      }
    end

    def read(operation, response)
      body = parse(response)
      return Receipt.new(status: body.fetch("status")) if response.status == 200 && conforms?(operation.dig("responses", "200"), body)
      raise problem(body) if response.status >= 400 && conforms?("common.json#/$defs/problem", body)

      raise ContractViolation, "HTTP #{response.status} is not an answer of the reservation API: #{response.body.to_s.truncate(200)}"
    end

    def parse(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end

    def conforms?(pointer, body)
      body.is_a?(Hash) && Timekeeping::Contracts.errors(CONTRACT, pointer, body).empty?
    end

    def problem(body)
      Problem.new(
        status: body.fetch("status"), type: body.fetch("type").delete_prefix(Timekeeping::Contracts::PROBLEM_BASE),
        retryable: body.fetch("retryable"), detail: body["detail"]
      )
    end

    def http
      @http ||= Faraday.new(url: @url, request: { timeout: TIMEOUT, open_timeout: TIMEOUT })
    end
end
