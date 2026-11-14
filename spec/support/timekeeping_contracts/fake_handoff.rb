# frozen_string_literal: true

require_relative "fake_timekeeping"

module TimekeepingContracts
  # The consumer-side fake of Timekeeping's handoff API (handoff_api.json;
  # docs/architecture/timekeeping-soa.md §10.5, §12.3) for the handoff tool:
  # an in-memory Rack app at FakeTimekeeping's URL that serves the handoff
  # paths exactly as the contract states them. FakeTimekeeping leaves those
  # paths to it, so both can be installed in one example.
  #
  # It keeps the protocol:
  #
  # - the handoff tool's service token, and the contract's headers;
  # - the generation the call carries, which must be the body's;
  # - Timekeeping's copy of the ownership record, moved by the one shared
  #   state machine (TimekeepingReservations::Handoff), so a replayed or
  #   misordered step is out-of-step and changes nothing;
  # - load and reconcile only while the copy is frozen under the legacy owner
  #   at the checkpoint's generation, and a second load already-loaded;
  # - reconcile against the checkpoint it loaded: an entry missing,
  #   unexpected or different, or another set of reservations for an entry,
  #   is checkpoint-differs with its lists, and nothing changes;
  # - the outbox: a load writes one entry snapshot per entry, at the version
  #   and with the `locked` the checkpoint carries, undelivered until #relay!
  #   delivers them, so the tool can wait for the drain (§10.5 step 3).
  #
  # Every request is checked against the contract; a consumer's mismatch
  # answers 400 and is recorded in #violations. Every answer the fake gives is
  # checked too, and a mismatch there raises, because it is a bug in the fake.
  #
  # Of the load's checkpoint-refused checks (§10.4) it keeps only the one the
  # outbox needs, not_a_contract_entry. It keeps none of the other rules of
  # Timekeeping's own services: the load's other refusals, the 60 s drain,
  # and the entry and reservation tables themselves. Those are tested in
  # services/timekeeping. A test that needs one of their refusals scripts it
  # with #fail_next.
  class FakeHandoff
    URL = FakeTimekeeping::URL
    SERVED = %r{\A#{Regexp.escape(URL)}/internal/v1/handoff(?:[/?]|\z)}
    CONTRACT = :handoff_api
    SUBJECT = "service:timekeeping-handoff"
    AUDIENCE = "handoff"
    PROBLEM = "common.json#/$defs/problem"
    SNAPSHOT_TYPE = "timekeeping.entry_snapshot.v1"

    HANDLERS = {
      read_handoff: :read_handoff, run_step: :run_step,
      load_checkpoint: :load_checkpoint, reconcile_checkpoint: :reconcile_checkpoint
    }.freeze

    # Timekeeping's copy of the ownership record (§10.1).
    Copy = Data.define(:generation, :owner, :state)

    Call = Data.define(:operation, :params, :input, :request_id)

    # `loaded` is the checkpoint the load stored, as carried: { "generation",
    # "entries", "reservations" }, or nil before a load.
    attr_reader :copy, :violations, :calls, :outbox, :loaded

    # The copy starts where Timekeeping's does before any handoff: the
    # column defaults, generation 0, legacy, open.
    def initialize(generation: 0, owner: "legacy", state: "open", token_key: TEST_TOKEN_KEY)
      @copy = Copy.new(generation:, owner:, state:)
      @token_key = token_key
      @loaded = nil
      @outbox = []
      @delivered = 0
      @scripted = []
      @violations = []
      @calls = []
    end

    # Serves every handoff request to URL from this fake for the rest of the
    # example.
    def install!
      WebMock::API.stub_request(:any, SERVED).to_rack(self)
      self
    end

    # The snapshots the relay has not yet delivered.
    def undelivered = @outbox.drop(@delivered)

    # Delivers every undelivered snapshot to `app`'s projection endpoint, as
    # the relay does, and marks them delivered. Answers each batch's receipt.
    def relay!(app = Rails.application)
      undelivered.each_slice(500).map do |batch|
        FakeRelay.new(token_key: @token_key).deliver(app, batch).tap { @delivered += batch.size }
      end
    end

    # The next call of operation answers this problem instead of running, and
    # changes nothing. `extensions` adds the problem's own members, such as
    # checkpoint-refused's lists.
    def fail_next(operation, status:, slug:, retryable: false, **extensions)
      @scripted << [operation, :fail, problem(status, slug, retryable:, **extensions)]
    end

    # The next call of operation runs, then its response is lost on the way
    # back: the client sees a read timeout, and the step may have run.
    def lose_next_response(operation)
      @scripted << [operation, :lose, nil]
    end

    def call(env)
      request = Rack::Request.new(env)
      status, body = catch(:halt) { serve(request) }
      TimekeepingContracts.validate!(CONTRACT, PROBLEM, body) if status >= 400
      [status, { "content-type" => status < 400 ? "application/json" : "application/problem+json" }, [JSON.generate(body)]]
    end

    private

      def serve(request)
        operation, params = route(request)
        authenticate(request)
        check_headers(request, operation)
        input = read_input(request, operation)
        check_generation(request, operation, input)
        @calls << Call.new(operation: operation.name, params:, input:, request_id: request.get_header("HTTP_X_REQUEST_ID"))
        script = take_script(operation.name)
        halt(*script.last) if script&.at(1) == :fail

        answer(operation, send(HANDLERS.fetch(operation.name), params, input))
          .tap { raise Net::ReadTimeout, "#{operation.name} response lost" if script&.at(1) == :lose }
      end

      def route(request)
        TimekeepingContracts.operations.each do |operation|
          next unless operation.contract == CONTRACT

          params = operation.match(request.request_method, request.path_info)
          return [operation, params] if params
        end
        halt(*problem(404, "not-found", detail: "#{request.request_method} #{request.path_info} is not in the contract"))
      end

      def authenticate(request)
        token = request.get_header("HTTP_AUTHORIZATION").to_s.delete_prefix("Bearer ")
        claims = TimekeepingContracts.decode(token, key: @token_key, audience: AUDIENCE)
        TimekeepingContracts.validate!(CONTRACT, "#/$defs/service_token_claims", claims)
      rescue JWT::DecodeError, Violation => error
        halt(*problem(401, "unauthenticated", detail: error.message))
      end

      def check_headers(request, operation)
        headers = TimekeepingContracts.headers(CONTRACT)
        required = headers.fetch("every") + (operation.mutating ? headers.fetch("mutating") : [])
        missing = required.reject { |name| request.get_header("HTTP_#{name.upcase.tr('-', '_')}").present? }
        violation!("missing headers: #{missing.join(', ')}") if missing.any?
      end

      def read_input(request, operation)
        return {} unless operation.request

        TimekeepingContracts.validate!(CONTRACT, operation.request, JSON.parse(request.body.read.presence || "{}"))
      rescue JSON::ParserError, Violation => error
        violation!(error.message)
      end

      def check_generation(request, operation, input)
        return unless operation.mutating

        carried = request.get_header("HTTP_X_OWNERSHIP_GENERATION")
        violation!("X-Ownership-Generation is not an integer") unless carried.match?(/\A\d+\z/)
        violation!("body generation differs from X-Ownership-Generation") unless input.fetch("generation") == carried.to_i
      end

      def take_script(name)
        index = @scripted.index { |scripted| scripted.first == name }
        @scripted.delete_at(index) if index
      end

      def answer(operation, (status, body))
        TimekeepingContracts.validate!(CONTRACT, operation.responses.fetch(status.to_s), body) if status < 400
        [status, body]
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

      def out_of_step!(error)
        halt(*problem(409, "out-of-step", detail: error.message))
      end

      # Handlers

      def read_handoff(_params, _input) = [200, status]

      def run_step(params, input)
        step = TimekeepingReservations::Handoff::STEPS[params.fetch("step").to_sym]
        halt(*problem(404, "not-found", detail: "#{params.fetch('step')} is not a handoff step")) unless step

        @copy = @copy.with(**step.apply(@copy, generation: input.fetch("generation")))
        [200, status]
      rescue TimekeepingReservations::Handoff::OutOfStep => error
        out_of_step!(error)
      end

      def load_checkpoint(_params, input)
        ensure_frozen_legacy!(:load, input.fetch("generation"))
        halt(*problem(409, "already-loaded", detail: "Timekeeping already holds entries; nothing loaded")) if @loaded
        ensure_contract_entries!(input.fetch("entries"))

        @loaded = input
        @outbox.concat(input.fetch("entries").sort_by { |entry| entry.fetch("id") }.map { |entry| snapshot(entry) })
        receipt(input)
      end

      def reconcile_checkpoint(_params, input)
        ensure_frozen_legacy!(:reconcile, input.fetch("generation"))
        lists = differences(input, @loaded || { "entries" => [], "reservations" => [] })
        halt(*problem(409, "checkpoint-differs", detail: "the checkpoint differs from what Timekeeping holds", lists:)) if lists.any?

        receipt(input)
      end

      # Where the provider's Ownership.lock_frozen_legacy! lets a load or a
      # reconcile run: frozen at the handoff's generation, under legacy.
      def ensure_frozen_legacy!(name, generation)
        TimekeepingReservations::Handoff.ensure_in_step!(name, %w[frozen], @copy, generation)
        return if @copy.owner == "legacy"

        raise TimekeepingReservations::Handoff::OutOfStep,
          "Timekeeping handoff: #{name} runs only for the first cutover, found owner #{@copy.owner}; nothing changed"
      rescue TimekeepingReservations::Handoff::OutOfStep => error
        out_of_step!(error)
      end

      def ensure_contract_entries!(entries)
        refused = entries.reject { |entry| TimekeepingContracts.valid?(:entry_api, "common.json#/$defs/entry", entry) }
        return if refused.empty?

        halt(*problem(422, "checkpoint-refused", detail: "the checkpoint does not hold together; nothing loaded",
          lists: { "not_a_contract_entry" => refused.map { |entry| entry.fetch("id") } }))
      end

      # The provider's list names, for what the fake can see: entries by id,
      # and each entry's set of reservations.
      def differences(carried, held)
        carried_entries, held_entries = [carried, held].map { |side| side.fetch("entries").index_by { |entry| entry.fetch("id") } }
        carried_holds, held_holds = [carried, held].map { |side| reservations_by_entry(side) }
        {
          "entry_missing" => carried_entries.keys - held_entries.keys,
          "entry_unexpected" => held_entries.keys - carried_entries.keys,
          "entry_differs" => (carried_entries.keys & held_entries.keys).reject { |id| carried_entries[id] == held_entries[id] },
          "reservations_differ" => (carried_holds.keys | held_holds.keys).reject { |id| carried_holds[id] == held_holds[id] }
        }.transform_values(&:sort).reject { |_, ids| ids.empty? }
      end

      def reservations_by_entry(side)
        side.fetch("reservations").group_by { |reservation| reservation.fetch("entry_id") }
          .transform_values { |reservations| reservations.sort_by { |reservation| reservation.fetch("invoice_id") } }
      end

      def snapshot(entry)
        TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", {
          "type" => SNAPSHOT_TYPE, "entry_id" => entry.fetch("id"), "version" => entry.fetch("version"),
          "company_id" => entry.fetch("company_id"), "data" => entry.except("id", "company_id", "version")
        })
      end

      def receipt(input)
        [200, { "entries" => input.fetch("entries").size, "reservations" => input.fetch("reservations").size }]
      end

      def status
        {
          "ownership" => @copy.to_h.transform_keys(&:to_s),
          "outbox" => { "latest_position" => (@outbox.size if @outbox.any?), "undelivered" => undelivered.size }
        }
      end
  end
end
