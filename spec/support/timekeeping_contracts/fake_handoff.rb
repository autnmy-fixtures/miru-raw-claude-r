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
  # - the rollback's take (take_checkpoint) only while the copy is frozen
  #   under the timekeeping owner at the query's generation. It answers what
  #   the fake holds as the owner (#held): the entries and reservations a load
  #   stored, and whatever a test sets with #hold! or #write!, as the writes
  #   Timekeeping took after the cutover. It writes nothing;
  # - the re-cutover's load (load_recutover_checkpoint) only while the copy is
  #   frozen under the monolith owner at the checkpoint's generation. It
  #   replaces what the fake holds with the checkpoint's six parts as carried,
  #   writes no outbox snapshot (freeze drained the prepared application's
  #   outbox into the projection), and run again holds the same and answers
  #   the same;
  # - reconcile against the checkpoint it loaded: an entry missing,
  #   unexpected or different, or another set of reservations for an entry,
  #   is checkpoint-differs with its lists, and nothing changes;
  # - the outbox: a load writes one entry snapshot per entry, at the version
  #   and with the `locked` the checkpoint carries, and #write! one per entry
  #   it writes, each undelivered until #relay! delivers them, so the tool can
  #   wait for the drain (§10.5 step 3).
  #
  # Every request is checked against the contract; a consumer's mismatch
  # answers 400 and is recorded in #violations. Every answer the fake gives is
  # checked too, and a mismatch there raises, because it is a bug in the fake.
  #
  # Of the loads' checkpoint-refused checks (§10.4) it keeps only those that
  # stop it holding a row the contract does not allow: not_a_contract_entry,
  # which the outbox needs, and for the re-cutover's load the checks on each
  # part a take must answer in taken_checkpoint's form (provisional_
  # reservation, not_a_contract_audit, not_a_terminal_receipt, not_a_contract_
  # idempotency_receipt), named and listed as RecutoverLoad lists them. It
  # keeps none of the other rules of Timekeeping's own services: the loads'
  # other refusals, the re-cutover's refusal of a checkpoint that would drop
  # what Timekeeping holds, the take's
  # checkpoint-unsettled (it holds no pending operation), the 60 s drain, and
  # the entry and reservation tables themselves. Those are tested in
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
      read_handoff: :read_handoff, run_step: :run_step, take_checkpoint: :take_checkpoint,
      load_checkpoint: :load_checkpoint, reconcile_checkpoint: :reconcile_checkpoint,
      load_recutover_checkpoint: :load_recutover_checkpoint
    }.freeze

    # The parts of a taken checkpoint (taken_checkpoint) other than its
    # generation: what Timekeeping holds as the owner.
    HELD = %w[entries reservations entry_audits reservation_operations idempotency_receipts].freeze

    # The re-cutover load's checks on a carried row that a take could not
    # answer (taken_checkpoint), by part: the list RecutoverLoad names, whether
    # a row may be held, and what identifies the row in that list. The request
    # already holds each reservation to the strict `reservation`, so only its
    # state is left to check.
    RECUTOVER_ROWS = {
      "entries" => ["not_a_contract_entry", ->(row) { TimekeepingContracts.valid?(:entry_api, "common.json#/$defs/entry", row) }, ->(row) { row.fetch("id") }],
      "reservations" => ["provisional_reservation", ->(row) { row.fetch("state") == "committed" }, ->(row) { row.fetch("entry_id") }],
      "entry_audits" => ["not_a_contract_audit", ->(row) { TimekeepingContracts.valid?(CONTRACT, "#/$defs/entry_audit", row) }, ->(row) { row.fetch("id") }],
      "reservation_operations" => [
        "not_a_terminal_receipt", ->(row) { TimekeepingContracts.valid?(CONTRACT, "#/$defs/operation_receipt", row) },
        ->(row) { row.values_at("invoice_id", "operation_id").join("/") }
      ],
      "idempotency_receipts" => [
        "not_a_contract_idempotency_receipt", ->(row) { TimekeepingContracts.valid?(CONTRACT, "#/$defs/idempotency_receipt", row) },
        ->(row) { row.values_at("company_id", "key").join("/") }
      ]
    }.freeze

    # Timekeeping's copy of the ownership record (§10.1).
    Copy = Data.define(:generation, :owner, :state)

    Call = Data.define(:operation, :params, :input, :request_id)

    # `loaded` is the checkpoint the load stored, as carried: { "generation",
    # "entries", "reservations" }, or nil before a load. `held` is what
    # Timekeeping holds as the owner, by HELD part, in the contract's form:
    # what the take answers.
    attr_reader :copy, :violations, :calls, :outbox, :loaded, :held

    # The copy starts where Timekeeping's does before any handoff: the
    # column defaults, generation 0, legacy, open.
    def initialize(generation: 0, owner: "legacy", state: "open", token_key: TEST_TOKEN_KEY)
      @copy = Copy.new(generation:, owner:, state:)
      @token_key = token_key
      @loaded = nil
      @held = HELD.index_with { [] }
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

    # Sets what Timekeeping holds as the owner, part by part (HELD), in the
    # contract's form, for the rollback's take to answer: the writes it took
    # after the cutover. A part not named keeps what it held. A part outside
    # the contract raises, because it is a bug in the test.
    def hold!(**parts)
      unknown = parts.keys.map(&:to_s) - HELD
      raise ArgumentError, "FakeHandoff holds only #{HELD.join(', ')}, not #{unknown.join(', ')}" if unknown.any?

      held = @held.merge(parts.transform_keys(&:to_s))
      TimekeepingContracts.validate!(CONTRACT, "#/$defs/taken_checkpoint", { "generation" => @copy.generation, **held })
      @held = held
      self
    end

    # Timekeeping takes these entry writes as the owner, in the contract's
    # full-entry form: each replaces the held entry of its id, or is added,
    # and its snapshot goes into the outbox, undelivered until #relay!
    # delivers it, so the rollback must drain it (§10.5 step 3). The test
    # bumps each entry's version, as Timekeeping's writes do.
    def write!(*entries)
      written = entries.index_by { |entry| entry.fetch("id") }
      held = @held.fetch("entries").reject { |entry| written.key?(entry.fetch("id")) } + written.values
      hold!(entries: held.sort_by { |entry| entry.fetch("id") })
      @outbox.concat(written.values.map { |entry| snapshot(entry) })
      self
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
        if operation.request
          TimekeepingContracts.validate!(CONTRACT, operation.request, JSON.parse(request.body.read.presence || "{}"))
        elsif operation.query
          TimekeepingContracts.validate!(CONTRACT, operation.query, Rack::Utils.parse_query(request.query_string))
        else
          {}
        end
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

      # The rollback's checkpoint out of Timekeeping, the outgoing owner: what
      # it holds, at the query's generation. A read.
      def take_checkpoint(_params, input)
        generation = Integer(input.fetch("generation"), 10)
        ensure_frozen!(:checkpoint, generation, owner: "timekeeping")

        [200, { "generation" => generation, **@held }]
      end

      def load_checkpoint(_params, input)
        ensure_frozen!(:load, input.fetch("generation"), owner: "legacy")
        halt(*problem(409, "already-loaded", detail: "Timekeeping already holds entries; nothing loaded")) if @loaded
        ensure_contract_entries!(input.fetch("entries"))

        @loaded = input
        @held = @held.merge(input.slice("entries", "reservations"))
        @outbox.concat(input.fetch("entries").sort_by { |entry| entry.fetch("id") }.map { |entry| snapshot(entry) })
        receipt(input)
      end

      def reconcile_checkpoint(_params, input)
        ensure_frozen!(:reconcile, input.fetch("generation"), owner: "legacy")
        lists = differences(input, @loaded || { "entries" => [], "reservations" => [] })
        halt(*problem(409, "checkpoint-differs", detail: "the checkpoint differs from what Timekeeping holds", lists:)) if lists.any?

        receipt(input)
      end

      # The re-cutover's checkpoint, taken out of the prepared application,
      # the outgoing monolith owner, loaded over what the fake holds from
      # before the rollback: the checkpoint's parts become what it holds, as
      # carried, so a later take answers them. No snapshot goes into the
      # outbox. Loading it again holds the same and answers the same.
      def load_recutover_checkpoint(_params, input)
        ensure_frozen!(:load, input.fetch("generation"), owner: "monolith")
        ensure_holdable!(input)

        hold!(**input.slice(*HELD).symbolize_keys)
        [200, HELD.index_with { |part| input.fetch(part).size }]
      end

      # Refuses a re-cutover checkpoint holding a row a take could not
      # answer, listing each, as RecutoverLoad lists them, and loads nothing.
      def ensure_holdable!(input)
        lists = RECUTOVER_ROWS.to_h do |part, (list, holdable, identify)|
          [list, input.fetch(part).reject(&holdable).map(&identify).uniq]
        end.reject { |_, found| found.empty? }
        return if lists.empty?

        halt(*problem(422, "checkpoint-refused", detail: "the checkpoint does not hold together; nothing loaded", lists:))
      end

      # Where the provider's Ownership.lock_frozen! lets a checkpoint step run:
      # frozen at the handoff's generation, under the outgoing owner, legacy
      # for the first cutover's load and reconcile, timekeeping for the
      # rollback's take, monolith for the re-cutover's load.
      def ensure_frozen!(name, generation, owner:)
        TimekeepingReservations::Handoff.ensure_in_step!(name, %w[frozen], @copy, generation)
        return if @copy.owner == owner

        raise TimekeepingReservations::Handoff::OutOfStep,
          "Timekeeping handoff: #{name} expects owner #{owner}, found owner #{@copy.owner}; nothing changed"
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
