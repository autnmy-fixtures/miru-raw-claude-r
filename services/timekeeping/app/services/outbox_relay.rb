# frozen_string_literal: true

require "jwt"
require "net/http"

# The relay of docs/architecture/timekeeping-soa.md §5.4: it delivers the
# outbox's entry snapshots to the projection consumer in the existing
# application, `POST /internal/v1/projection/entry_snapshots` at
# EXISTING_APP_URL, in batches of up to BATCH_SIZE in outbox order. It runs on
# its own queue and worker (OutboxRelayJob, config/solid_queue.yml).
#
# One batch is one transaction: the undelivered rows are taken FOR UPDATE
# SKIP LOCKED, so a second relay delivers other rows or none, posted, and
# marked delivered only once the consumer answers the contract's 200 receipt,
# which means the whole batch is durable there. Any other answer, or none,
# rolls the batch back unmarked; the next run sends it again. The consumer
# upserts by (entry_id, version) and ignores anything not newer, so sending a
# batch twice, or out of order, is harmless. Nothing is ever skipped: a batch
# the consumer refuses stays at the head of the outbox and is reported on
# every run until it is fixed.
#
# The call carries the relay's service token (entry_snapshot.json
# service_token_claims) and its own X-Request-Id; the request ids of the
# changes it carries are logged against it (§11.3).
class OutboxRelay
  BATCH_SIZE = 500 # the import batch's size (§3.4), and the entry list's page

  # The delivery's budget. §9.4's 2 s is for the gateway's calls; one batch
  # here upserts up to 500 rows. Bounded, so a hung consumer releases the
  # batch's row locks and the next run tries again.
  TIMEOUT = 10 # seconds

  TOKEN_TTL = 60 # seconds, §6.1
  CONTRACT = :entry_snapshot
  OPERATION = "deliver_snapshots"

  class Error < StandardError; end

  # No EXISTING_APP_URL or no shared token key in this process (§11.2).
  class NotConfigured < Error; end

  # A batch the consumer did not confirm with the contract's 200 receipt: it
  # answered something else, or the call never reached it or never came back.
  class Undelivered < Error
    attr_reader :batch

    def initialize(message, batch:)
      @batch = batch
      super(message)
    end
  end

  # A delivery that never reached the consumer, or never came back.
  TRANSPORT_ERRORS = [Timeout::Error, SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse].freeze

  Result = Data.define(:delivered, :undelivered)

  def initialize(url: config.existing_app_url, token_key: config.token_key, batch_size: BATCH_SIZE, clock: -> { Time.current })
    raise NotConfigured, "EXISTING_APP_URL is not set" if url.blank?
    raise NotConfigured, "TIMEKEEPING_TOKEN_KEY is not set" if token_key.blank?

    @endpoint = URI.join(url, operation.fetch("path"))
    @token_key, @batch_size, @clock = token_key, batch_size, clock
  end

  # Delivers batch after batch until the outbox has no undelivered row left
  # that this relay can take, or a batch is not delivered. Answers how many
  # snapshots were delivered, and how many of the last batch were not.
  def run
    delivered = 0
    loop do
      sent = deliver_batch
      delivered += sent
      return Result.new(delivered:, undelivered: 0) if sent < @batch_size
    end
  rescue Undelivered => error
    # Logged as well as reported: this service has no error subscriber yet,
    # and a stalled relay must show where the worker's output goes.
    Rails.logger.error("relay: #{error.message}")
    Rails.error.report(error, handled: true, context: { relay: "outbox", delivered: })
    Result.new(delivered:, undelivered: error.batch)
  end

  private

    def config = Rails.configuration.x.timekeeping

    def operation = Contracts.document(CONTRACT).fetch("x-operations").fetch(OPERATION)

    # The number of snapshots delivered: 0 when the outbox had nothing to take.
    def deliver_batch
      OutboxSnapshot.transaction do
        rows = OutboxSnapshot.undelivered.limit(@batch_size).lock("FOR UPDATE SKIP LOCKED").to_a
        next 0 if rows.empty?

        post(rows)
        OutboxSnapshot.where(id: rows.map(&:id)).update_all(delivered_at: @clock.call)
        rows.size
      end
    end

    def post(rows)
      request_id = SecureRandom.uuid
      Rails.logger.info(
        "relay #{request_id}: outbox #{rows.first.id}..#{rows.last.id}, #{rows.size} snapshots, requests #{rows.map(&:request_id).uniq.join(', ')}"
      )
      response = http.request(request(rows, request_id))
      return if receipt?(response)

      raise Undelivered.new("relay #{request_id}: the projection answered #{response.code}: #{response.body.to_s.truncate(200)}", batch: rows.size)
    rescue *TRANSPORT_ERRORS => error
      raise Undelivered.new("relay #{request_id}: #{error.class}: #{error.message}", batch: rows.size)
    end

    def request(rows, request_id)
      Net::HTTP::Post.new(@endpoint).tap do |request|
        request["Authorization"] = "Bearer #{service_token}"
        request["X-Request-Id"] = request_id
        request["Content-Type"] = "application/json"
        request.body = JSON.generate({ "snapshots" => rows.map(&:snapshot) })
      end
    end

    # The contract's success: 200 with a delivery receipt.
    def receipt?(response)
      expected = operation.dig("responses", response.code)
      return false unless expected

      body = JSON.parse(response.body.to_s)
      body.is_a?(Hash) && Contracts.errors(CONTRACT, expected, body).empty?
    rescue JSON::ParserError
      false
    end

    def service_token
      now = @clock.call.to_i
      JWT.encode({ "sub" => "service:timekeeping-relay", "aud" => "projection", "iat" => now, "exp" => now + TOKEN_TTL }, @token_key, "HS256")
    end

    def http
      Net::HTTP.new(@endpoint.host, @endpoint.port).tap do |http|
        http.use_ssl = @endpoint.scheme == "https"
        http.open_timeout = http.read_timeout = http.write_timeout = TIMEOUT
      end
    end
end
