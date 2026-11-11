# frozen_string_literal: true

module TimekeepingContracts
  # The consumer-side fake of Timekeeping (docs/architecture/timekeeping-soa.md
  # §12.3) for the gateway and invoice-boundary lanes: an in-memory Rack app that
  # serves the entry API and the reservation API exactly as their contracts
  # state them.
  #
  # It keeps the protocol: tokens, required headers, the ownership generation,
  # entry API idempotency receipts, tenant scoping by the token's company,
  # terminal receipts per (invoice, operation), at most one unresolved operation
  # per invoice, and exclusivity refusals (F1, L8). Every request is checked
  # against its schema; a consumer's mismatch answers 400 and is recorded in
  # #violations. Every answer the fake gives is checked too, and a mismatch there
  # raises, because it is a bug in the fake.
  #
  # It keeps none of the business rules: no A1-A11 checks, no model
  # validations, no edit_lock or retained reservations, and no version bump or
  # snapshot on a reservation change. Those belong to Timekeeping itself and to
  # the shared decision table (§7.2), which is tested row by row in its package.
  class FakeTimekeeping
    URL = "http://timekeeping.test"
    SERVED = %r{\A#{Regexp.escape(URL)}/}
    CONTRACTS = %i[entry_api reservation_api].freeze

    HANDLERS = {
      create_entry: :create_entry, update_entry: :update_entry, discard_entry: :discard_entry,
      bulk_move: :bulk_move, bulk_discard: :bulk_discard, import_batch: :import_batch,
      detach_agent: :detach_agent, list_entries: :list_entries, show_entry: :show_entry,
      candidates: :candidates, prepare: :prepare_operation, commit: :commit_operation, abort: :abort_operation
    }.freeze

    # An entry's one reservation, as far as the protocol sees it.
    Holding = Data.define(:invoice_id, :operation_id, :state)

    # What an outcome does to each holding of its invoice; nil releases it.
    # Commit makes the desired set the invoice's set; abort drops the
    # provisional holdings, which only the one unresolved operation can own.
    OUTCOMES = {
      "committed" => ->(holding, entry_id, desired) { holding.with(state: :committed) if desired.include?(entry_id) },
      "aborted" => ->(holding, _entry_id, _desired) { holding unless holding.state == :provisional }
    }.freeze

    PROBLEM = "common.json#/$defs/problem"

    Call = Data.define(:operation, :params, :input, :claims)

    attr_reader :violations, :calls
    attr_accessor :generation

    def initialize(generation: 1, token_key: TEST_TOKEN_KEY, clock: -> { Time.current })
      @generation = generation
      @token_key = token_key
      @clock = clock
      @entries = {}
      @holdings = {}
      @operations = {}
      @receipts = {}
      @scripted = []
      @violations = []
      @calls = []
      @last_id = 0
    end

    # Serves every request to URL from this fake for the rest of the example.
    def install!
      WebMock::API.stub_request(:any, SERVED).to_rack(self)
      self
    end

    # An entry Timekeeping already owns, as if copied at cutover.
    def seed_entry(company_id:, **attributes)
      store(build_entry(company_id:, attributes: attributes.transform_keys(&:to_s)))
    end

    def entry(id) = @entries[id]

    def holding(entry_id) = @holdings[entry_id]

    # The next call of operation answers this problem instead of running.
    def fail_next(operation, status:, slug:, retryable:)
      @scripted << [operation, :fail, problem(status, slug, retryable:)]
    end

    # The next call of operation runs, then its response is lost on the way
    # back: the client sees a read timeout (§9.3 "lost response").
    def lose_next_response(operation)
      @scripted << [operation, :lose, nil]
    end

    def call(env)
      request = Rack::Request.new(env)
      status, body = catch(:halt) { serve(request) }
      TimekeepingContracts.validate!(:entry_api, PROBLEM, body) if status >= 400
      [status, { "content-type" => status < 400 ? "application/json" : "application/problem+json" }, [JSON.generate(body)]]
    end

    private

      def serve(request)
        operation, params = route(request)
        claims = authenticate(request)
        check_headers(request, operation)
        input = read_input(request, operation)
        check_generation(request, operation, input)
        @calls << Call.new(operation: operation.name, params:, input:, claims:)
        script = take_script(operation.name)
        halt(*script.last) if script&.at(1) == :fail

        answer(operation, replayable(request, operation, input) { send(HANDLERS.fetch(operation.name), params, input, claims) })
          .tap { raise Net::ReadTimeout, "#{operation.name} response lost" if script&.at(1) == :lose }
      end

      def route(request)
        TimekeepingContracts.operations.each do |operation|
          next unless CONTRACTS.include?(operation.contract)

          params = operation.match(request.request_method, request.path_info)
          return [operation, params] if params
        end
        halt(*problem(404, "not-found", detail: "#{request.request_method} #{request.path_info} is not in the contract"))
      end

      def authenticate(request)
        token = request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")
        claims = TimekeepingContracts.decode(token, key: @token_key, audience: "timekeeping")
        TimekeepingContracts.validate!(:entry_api, "#/$defs/token_claims", claims)
      rescue JWT::DecodeError, Violation => error
        halt(*problem(401, "unauthenticated", detail: error.message))
      end

      def check_headers(request, operation)
        headers = TimekeepingContracts.headers(operation.contract)
        required = headers.fetch("every") + (operation.mutating ? headers.fetch("mutating") : [])
        missing = required.reject { |name| request.get_header("HTTP_#{name.upcase.tr('-', '_')}").present? }
        violation!("missing headers: #{missing.join(', ')}") if missing.any?
      end

      def read_input(request, operation)
        if operation.request
          body = JSON.parse(request.body.read.presence || "{}")
          contract_check(operation.contract, operation.request, body)
        elsif operation.query
          contract_check(operation.contract, operation.query, Rack::Utils.parse_nested_query(request.query_string))
        else
          {}
        end
      rescue JSON::ParserError => error
        violation!("body is not JSON: #{error.message}")
      end

      def check_generation(request, operation, input)
        return unless operation.mutating

        carried = request.get_header("HTTP_X_OWNERSHIP_GENERATION")
        violation!("X-Ownership-Generation is not an integer") unless carried.match?(/\A\d+\z/)
        violation!("body generation differs from X-Ownership-Generation") if input.key?("generation") && input["generation"] != carried.to_i
        if operation.contract == :reservation_api && request.get_header("HTTP_IDEMPOTENCY_KEY") != operation_id_of(request, operation)
          violation!("Idempotency-Key must be the operation_id")
        end
        halt(*problem(409, "stale-generation", retryable: false)) unless carried.to_i == generation
      end

      def operation_id_of(request, operation)
        operation.match(request.request_method, request.path_info).fetch("operation_id")
      end

      def take_script(name)
        index = @scripted.index { |scripted| scripted.first == name }
        @scripted.delete_at(index) if index
      end

      # Entry API receipts (§9.4): same key and body replays the stored
      # response, same key and another body is refused.
      def replayable(request, operation, input)
        return yield unless operation.mutating && operation.contract == :entry_api

        key = request.get_header("HTTP_IDEMPOTENCY_KEY")
        digest = Digest::SHA256.hexdigest([request.request_method, request.path_info, JSON.generate(input)].join("\n"))
        stored_digest, response = @receipts[key]
        return response if stored_digest == digest
        halt(*problem(409, "idempotency-conflict", retryable: false)) if stored_digest

        yield.tap { |fresh| @receipts[key] = [digest, fresh] }
      end

      def answer(operation, (status, body))
        TimekeepingContracts.validate!(operation.contract, operation.responses.fetch(status.to_s), body) if status < 400
        [status, body]
      end

      def contract_check(contract, pointer, payload)
        TimekeepingContracts.validate!(contract, pointer, payload)
      rescue Violation => error
        violation!(error.message)
      end

      def violation!(detail)
        @violations << detail
        halt(*problem(400, "invalid-request", detail:))
      end

      def halt(status, body)
        throw :halt, [status, body]
      end

      def problem(status, slug, retryable: false, **extensions)
        [status, { "type" => TimekeepingContracts.problem_type(slug), "title" => slug.tr("-", " ").capitalize, "status" => status, "retryable" => retryable, **extensions.transform_keys(&:to_s) }]
      end

      # Entry API

      def create_entry(_params, input, claims)
        [201, { "entry" => store(new_entry(input.fetch("entry"), claims)) }]
      end

      def update_entry(params, input, claims)
        [200, { "entry" => change(find!(params, claims), input.fetch("entry")) }]
      end

      def discard_entry(params, _input, claims)
        [200, { "entry" => change(find!(params, claims), "discarded_at" => timestamp) }]
      end

      def bulk_move(_params, input, claims)
        moved = kept_in(claims, input.fetch("ids")).map { |entry| change(entry, "project_id" => input.fetch("project_id")) }
        [200, { "moved_ids" => moved.pluck("id"), "skipped_ids" => [], "entries" => moved }]
      end

      def bulk_discard(_params, input, claims)
        discarded = kept_in(claims, input.fetch("ids")).map { |entry| change(entry, "discarded_at" => timestamp) }
        [200, { "discarded_ids" => discarded.pluck("id") }]
      end

      def import_batch(_params, input, claims)
        created = input.fetch("rows").map { |row| store(new_entry(row, claims)) }
        [200, { "created_ids" => created.pluck("id"), "failed_rows" => [] }]
      end

      def detach_agent(params, _input, claims)
        agent_id = Integer(params.fetch("agent_id"))
        detached = scoped(claims).filter_map { |entry| change(entry, "agent_id" => nil) if entry["agent_id"] == agent_id }
        [200, { "detached_ids" => detached.pluck("id") }]
      end

      def list_entries(_params, query, claims)
        entries = kept(claims).select do |entry|
          (query["user_id"].nil? || entry["user_id"] == Integer(query["user_id"])) && within?(entry, query)
        end
        [200, { "entries" => entries, "next_cursor" => nil }]
      end

      def show_entry(params, _input, claims)
        [200, { "entry" => find!(params, claims) }]
      end

      # Kept, unbilled, unheld entries of the given projects (§5.2).
      def candidates(_params, query, claims)
        ids = ->(key) { Array(query[key]).map { |id| Integer(id) } }
        entries = kept(claims).select do |entry|
          entry["bill_status"] == "unbilled" && !@holdings.key?(entry["id"]) &&
            ids.call("project_ids").include?(entry["project_id"]) &&
            (query["user_ids"].nil? || ids.call("user_ids").include?(entry["user_id"])) &&
            ids.call("exclude_ids").exclude?(entry["id"]) &&
            entry["note"].to_s.downcase.include?(query["search_term"].to_s.downcase) &&
            within?(entry, query)
        end
        [200, { "entries" => entries }]
      end

      # Reservation API

      def prepare_operation(params, input, claims)
        invoice_id, operation_id = operation_key(params)
        if input.fetch("company_id") != claims.fetch("company_id")
          return problem(403, "forbidden", detail: "company_id differs from the token's company")
        end

        receipt = terminal_receipt(invoice_id, operation_id)
        return receipt if receipt

        settle_earlier(invoice_id, operation_id, input.fetch("resolves"))
        entry_ids = input.fetch("entry_ids")
        refused = entry_ids.filter_map { |id| refusal(id, invoice_id, claims) }
        return problem(409, "reservation-refused", refused:) if refused.any?

        entry_ids.each { |id| @holdings[id] ||= Holding.new(invoice_id:, operation_id:, state: :provisional) }
        @operations[[invoice_id, operation_id]] = { state: :prepared, entry_ids: }
        [200, { "status" => "prepared", "entries" => entry_ids.map { |id| prepared_entry(@entries.fetch(id)) } }]
      end

      def commit_operation(params, _input, _claims)
        invoice_id, operation_id = operation_key(params)
        return problem(404, "not-found", detail: "operation #{operation_id} was never prepared") unless @operations.key?([invoice_id, operation_id])

        terminal_receipt(invoice_id, operation_id) || resolve(invoice_id, operation_id, "committed")
      end

      def abort_operation(params, _input, _claims)
        invoice_id, operation_id = operation_key(params)
        terminal_receipt(invoice_id, operation_id) || resolve(invoice_id, operation_id, "aborted")
      end

      def operation_key(params)
        [Integer(params.fetch("invoice_id")), params.fetch("operation_id")]
      end

      def terminal_receipt(invoice_id, operation_id)
        state = @operations.dig([invoice_id, operation_id], :state)
        [200, { "status" => state.to_s }] if %i[committed aborted].include?(state)
      end

      # An invoice has at most one unresolved operation; a new prepare either
      # carries its outcome or is refused as retryable (§5.3).
      def settle_earlier(invoice_id, operation_id, resolves)
        earlier = @operations.find { |(invoice, operation), record| invoice == invoice_id && operation != operation_id && record[:state] == :prepared }&.first
        return unless earlier
        halt(*problem(409, "operation-unresolved", retryable: true)) unless resolves&.fetch("operation_id") == earlier.last

        resolve(invoice_id, earlier.last, resolves.fetch("outcome"))
      end

      # Records the terminal outcome. An abort of an unknown operation is a
      # no-op that still leaves a receipt (§9.3).
      def resolve(invoice_id, operation_id, outcome)
        desired = @operations.dig([invoice_id, operation_id], :entry_ids) || []
        apply = OUTCOMES.fetch(outcome)
        @holdings = @holdings.to_h do |entry_id, holding|
          [entry_id, holding.invoice_id == invoice_id ? apply.call(holding, entry_id, desired) : holding]
        end.compact
        @operations[[invoice_id, operation_id]] = { state: outcome.to_sym, entry_ids: desired }
        [200, { "status" => outcome }]
      end

      # The first refusal that applies, in order (F1, L8).
      def refusal(entry_id, invoice_id, claims)
        entry = @entries[entry_id]
        holding = @holdings[entry_id]
        reason = {
          "not_found" => -> { entry.nil? },
          "wrong_company" => -> { entry["company_id"] != claims.fetch("company_id") },
          "on_other_invoice" => -> { holding && holding.invoice_id != invoice_id }
        }.find { |_, applies| applies.call }&.first
        { "entry_id" => entry_id, "reason" => reason } if reason
      end

      def prepared_entry(entry)
        entry.slice("id", "company_id", "project_id", "user_id", "duration", "work_date", "version")
      end

      # Storage

      def new_entry(attributes, claims)
        build_entry(
          company_id: claims.fetch("company_id"),
          attributes: attributes.merge("agent_id" => claims.dig("actor", "agent_id"))
        )
      end

      def build_entry(company_id:, attributes:)
        now = timestamp
        ENTRY_DEFAULTS
          .merge("id" => @last_id += 1, "company_id" => company_id, "version" => 1, "created_at" => now, "updated_at" => now)
          .merge(attributes)
      end

      def store(entry)
        TimekeepingContracts.validate!(:entry_api, "common.json#/$defs/entry", entry)
        @last_id = [@last_id, entry.fetch("id")].max
        @entries[entry.fetch("id")] = entry.freeze
      end

      def change(entry, attributes)
        store(entry.merge(attributes, "version" => entry.fetch("version") + 1, "updated_at" => timestamp))
      end

      def scoped(claims)
        @entries.values.select { |entry| entry["company_id"] == claims.fetch("company_id") }
      end

      def kept(claims)
        scoped(claims).select { |entry| entry["discarded_at"].nil? }
      end

      def kept_in(claims, ids)
        kept(claims).select { |entry| ids.include?(entry["id"]) }
      end

      def find!(params, claims)
        kept_in(claims, [Integer(params.fetch("id"))]).first or halt(*problem(404, "not-found"))
      end

      def within?(entry, query)
        (query["from"].nil? || entry["work_date"] >= query["from"]) && (query["to"].nil? || entry["work_date"] <= query["to"])
      end

      def timestamp
        @clock.call.utc.iso8601(6)
      end
  end
end
