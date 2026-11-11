# frozen_string_literal: true

# The `timekeeping` owner's side of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3), over HTTP: prepare of one
# ledger intent for the invoice reservation boundary, and commit and abort for
# the invoice operation worker. Paths, headers and bodies come from the
# reservation API contract, its one source of truth.
#
# Each call carries the intent's own generation and its operation id as the
# Idempotency-Key, so a resend after a lost response is the same request
# (§9.4), and a system-actor token for the intent's company (§6.1). Prepare
# answers Prepared, or the terminal Receipt Timekeeping stored for an
# operation already resolved; commit and abort answer the Receipt. Anything
# else raises: a problem Timekeeping answered, an answer outside the contract,
# or a transport error (Faraday::Error, a 2 s timeout included). This client
# never retries on its own: the boundary retries prepare (§9.4), and the
# worker's next sweep is the retry of commit and abort.
class Timekeeping::ReservationClient
  CONTRACT = :reservation_api
  TIMEOUT = 2 # seconds, §9.2 step 2 and §9.4
  WRITER = "invoice"

  Receipt = Data.define(:status)
  # 200 prepared: the desired set's entries, authoritative for existence and
  # company (L8), with the facts line-item validation needs.
  Prepared = Data.define(:entries)
  PreparedEntry = Data.define(:id, :company_id, :project_id, :user_id, :duration, :work_date, :version)

  # A 200 answer by its status: prepare's own, or a stored terminal receipt.
  # The contract allows "prepared" only from prepare.
  ANSWERS = {
    "prepared" => ->(body) { Prepared.new(entries: body.fetch("entries").map { |entry| PreparedEntry.new(**entry.symbolize_keys) }) },
    "committed" => ->(body) { Receipt.new(status: body.fetch("status")) },
    "aborted" => ->(body) { Receipt.new(status: body.fetch("status")) }
  }.freeze

  class Error < StandardError; end

  # Timekeeping is not configured here: no URL or no shared token key.
  class NotConfigured < Error; end

  # Timekeeping answered application/problem+json (§5.1).
  class Problem < Error
    attr_reader :status, :type, :retryable, :refused

    # `refused` lists, for reservation-refused only, every entry prepare
    # refused and why (F1, L8), as the shared rule's Refusal.
    def initialize(status:, type:, retryable:, detail: nil, refused: [])
      @status, @type, @retryable, @refused = status, type, retryable, refused
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

  # §9.2 step 2. `resolves` is nil, or the outcome of the invoice's earlier
  # operation Timekeeping may still hold unresolved (§5.3).
  def prepare(intent, invoice_state:, resolves:)
    request(:prepare, intent, {
      "company_id" => intent.company_id, "generation" => intent.generation, "kind" => intent.kind,
      "invoice_state" => invoice_state.to_s, "entry_ids" => intent.entry_ids, "resolves" => resolves
    })
  end

  def commit(intent) = request(:commit, intent, "generation" => intent.generation)

  def abort(intent) = request(:abort, intent, "generation" => intent.generation)

  private

    def config = Rails.configuration.x.timekeeping

    def request(name, intent, body)
      operation = Timekeeping::Contracts.document(CONTRACT).fetch("x-operations").fetch(name.to_s)
      response = http.post(path(operation, intent), JSON.generate(body), headers(intent))
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
      return ANSWERS.fetch(body.fetch("status")).call(body) if response.status == 200 && conforms?(operation.dig("responses", "200"), body)
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
        retryable: body.fetch("retryable"), detail: body["detail"],
        refused: body.fetch("refused", []).map { |refusal| TimekeepingReservations::Refusal.new(entry_id: refusal.fetch("entry_id"), reason: refusal.fetch("reason").to_sym) }
      )
    end

    def http
      @http ||= Faraday.new(url: @url, request: { timeout: TIMEOUT, open_timeout: TIMEOUT })
    end
end
