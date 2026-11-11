# frozen_string_literal: true

module TimekeepingContracts
  # The consumer-side fake of the Timekeeping relay (docs/architecture/
  # timekeeping-soa.md §5.4, §12.3) for the projection-consumer lane. It builds
  # entry snapshots that match the contract and delivers them in batches, as the
  # relay does, including the duplicates and reordering the consumer must
  # tolerate. Each delivery is checked against the contract on the way out and
  # its receipt on the way back.
  class FakeRelay
    Delivery = Data.define(:path, :headers, :body)

    # How a batch is put on the wire.
    ORDERS = {
      as_given: ->(snapshots) { snapshots },
      duplicated: ->(snapshots) { snapshots + snapshots },
      reversed: ->(snapshots) { snapshots.reverse }
    }.freeze

    def initialize(token_key: TEST_TOKEN_KEY)
      @token_key = token_key
    end

    # One snapshot of an entry at a version. data gives the entry's columns;
    # project_id, user_id, duration and work_date have no default.
    def snapshot(entry_id:, version:, company_id:, **data)
      now = Time.current.utc.iso8601(6)
      TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", {
        "type" => "timekeeping.entry_snapshot.v1", "entry_id" => entry_id, "version" => version, "company_id" => company_id,
        "data" => ENTRY_DEFAULTS.merge("created_at" => now, "updated_at" => now).merge(data.transform_keys(&:to_s))
      })
    end

    # The request the relay sends for a batch, for a request spec to post.
    def delivery(snapshots, order: :as_given)
      body = TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/snapshot_batch", { "snapshots" => ORDERS.fetch(order).call(snapshots) })
      Delivery.new(
        path: TimekeepingContracts.operation(:deliver_snapshots).path,
        headers: {
          "Authorization" => "Bearer #{service_token}",
          "X-Request-Id" => SecureRandom.uuid,
          "Content-Type" => "application/json"
        },
        body: JSON.generate(body)
      )
    end

    def service_token
      claims = { "sub" => "service:timekeeping-relay", "aud" => "projection" }
      token = TimekeepingContracts.sign(claims, key: @token_key)
      TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/service_token_claims", JWT.decode(token, @token_key, true, algorithm: "HS256").first)
      token
    end

    # Delivers a batch to a Rack app and returns its receipt, checked against
    # the contract. A non-2xx answer raises, as the relay would retry it.
    def deliver(app, snapshots, order: :as_given)
      request = delivery(snapshots, order:)
      env = request.headers.transform_keys { |name| "HTTP_#{name.upcase.tr('-', '_')}" }
        .merge("CONTENT_TYPE" => "application/json", :input => request.body)
      response = Rack::MockRequest.new(app).post(request.path, env)
      raise Violation, "delivery answered #{response.status}: #{response.body}" unless response.successful?

      TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/delivery_receipt", JSON.parse(response.body))
    end
  end
end
