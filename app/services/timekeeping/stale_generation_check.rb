# frozen_string_literal: true

# The stale-generation part of docs/architecture/timekeeping-soa.md §12.4's
# failure injection, against the two running applications of the local demo
# (§11.2): the §9.3 row
#
#   Stale generation | 409 stale-generation | Gateway re-reads ownership;
#   the command is retried against the current owner only if it was never
#   admitted
#
# and §13 item 6's "a stale generation". A stale generation is what a command
# carries when it was admitted under a generation that a handoff has since
# raised: a queued job, or a call that was already on its way (§10.1). The
# check sends such calls to the running Timekeeping, the owner, carrying the
# generation before the current one and, for one call, the generation after
# it. Each call is built the way the gateway, the invoice reservation boundary
# or the invoice operation worker build it. Only the generation is changed.
#
# It runs while Timekeeping owns the entries with admission open (after the
# first cutover or a re-cutover), in one step: nothing is stopped or started,
# and no handoff runs. On each seeded business:
#
#   never admitted  the employee's create of entry X, carrying the old and
#                   then the next generation, is refused 409
#                   stale-generation, not retryable. So is the gateway's own
#                   send of that create under the old generation, which the
#                   gateway answers as the public retryable 503 ownership-
#                   moving. Timekeeping holds no entry X after any of them.
#                   The employee then retries over the public API: the
#                   gateway re-reads ownership, sends the create under the
#                   current generation, and Timekeeping holds exactly one X
#   admitted        the employee's update of X goes through under the current
#                   generation. Its retry, with the same Idempotency-Key and
#                   the old generation, is refused and changes nothing. Its
#                   retry under the current generation is answered the stored
#                   result, and X is unchanged: an admitted command is never
#                   run again
#   reservations    the admin saves a draft holding X, and its commit is
#                   delivered. A prepare that adds entry Y to the draft,
#                   carrying the old generation, is refused, and Y is still
#                   offered. So are a commit and an abort of the draft's
#                   committed operation carrying the old generation. The
#                   commit under the current generation is answered its
#                   stored `committed` receipt. X and Y on Timekeeping, and the
#                   draft's rows of the ledger, are unchanged. The admin then
#                   retries the save adding Y over the public API, and it goes
#                   through
#
# Every refusal is also the §11.3 alert "stale-generation refusals outside a
# handoff". The existing application reports it through Rails.error while the
# call runs, and the check counts those reports. Timekeeping logs its own
# report, tagged with the request id the call carried, and the last line of
# the run names those request ids, so bin/timekeeping-demo stale-generation
# can find each one in timekeeping-web's log. Any check that does not hold
# raises Failed. A run that finishes deletes its draft and discards X and Y.
class Timekeeping::StaleGenerationCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  DURATIONS = { "X" => 40.0, "Y" => 50.0 }.freeze

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # The last line of a run starts with this, then the request ids of every
  # call that was refused, separated by spaces.
  REFUSED_LINE = "refused request ids:"

  # The existing application's stale-generation alerts (Timekeeping::Signals,
  # §11.3), as Rails.error receives them while one call runs.
  class Alerts
    attr_reader :reported

    def initialize
      @reported = []
    end

    def report(error, **)
      @reported << error if error.is_a?(Timekeeping::Signals::Alert) && error.signal == :stale_generation
    end
  end

  # The reservation client, with the X-Request-Id given to it, so Timekeeping
  # tags its log line for the alert with an id the check knows.
  class NamedReservationClient < Timekeeping::ReservationClient
    def initialize(request_id:, **)
      super(**)
      @request_id = request_id
    end

    private

      def identity_headers(company:, writer:)
        token_headers(Timekeeping::UserToken.system_claims(company:, writer:, request_id: @request_id))
      end
  end

  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
    @refused = []
  end

  def call
    @ownership = ensure_timekeeping_owns!
    @options.tenants.each { |tenant| check_tenant(prepare_tenant(tenant)) }
    say "every call carrying generation #{stale} or #{ahead} was refused with 409 stale-generation and changed " \
        "nothing; the gateway's retry of a command never admitted went through, and an admitted command's retry " \
        "was answered its stored result, on #{@options.tenants.size} businesses, at generation #{current}"
    say "#{REFUSED_LINE} #{@refused.join(' ')}"
  end

  private

    def log_prefix = "stale generation"

    def wait = @options.wait

    def current = @ownership.generation

    def stale = current - 1

    def ahead = current + 1

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner_timekeeping? && ownership.state_open?

      fail! "the stale-generation proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(letter) = "Stale generation #{@run} #{letter}"

    def number(tenant) = "STG-#{tenant[:company].id}-#{@run}"

    def check_tenant(tenant)
      held = never_admitted(tenant)
      admitted(tenant, held)
      added = create_entry(tenant, "Y")
      draft_id = reservations(tenant, held, added)
      clean_up(tenant, draft_id, [held, added])
    end

    # --- never admitted: refused, then retried by the gateway ---------------

    def never_admitted(tenant)
      entry = Entry.new(duration: DURATIONS.fetch("X"), note: note("X"))
      command = create_command(tenant, entry)
      key = SecureRandom.uuid
      [stale, ahead].each do |generation|
        refused!(tenant, "the create of entry X carrying generation #{generation}") do |request_id|
          forward(tenant, command, generation:, key:, request_id:)
        end
      end
      not_written!(tenant, entry, after: "the refused creates")

      gateway_moving!(tenant, command)
      not_written!(tenant, entry, after: "the gateway's refused send")

      retried_create!(tenant, entry)
      say "#{tenant[:name]}: creates of entry X carrying generations #{stale} and #{ahead}, and the gateway's send under " \
          "#{stale}, were refused and wrote nothing; the employee's retry was sent under generation #{current} and " \
          "Timekeeping holds it once, as entry #{entry.id}"
      entry
    end

    # The employee's own retry, over the public API: the gateway re-reads
    # ownership and sends the create under the current generation.
    def retried_create!(tenant, entry)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: entry.duration, note: entry.note))
      expect_ok!(response, "retry the create of entry X for #{tenant[:name]}")
      id = entry.id = response.json.dig("entry", "id")
      held = owner_entries(tenant, entry).map { |row| row.fetch("id") }
      fail! "#{tenant[:name]}: after the retry, Timekeeping holds entries #{held} noted #{entry.note.inspect}, not [#{id}]" unless held == [id]
    end

    # The gateway's own send of the command under a record read at the old
    # generation: what reaches the remote owner when a handoff raised the
    # generation after the record was read. The public API answers the
    # Moving it raises as 503 with this message.
    def gateway_moving!(tenant, command)
      what = "the gateway's send of the create of entry X under generation #{stale}"
      read_before = Timekeeping::Ownership.current.dup.tap { |ownership| ownership.generation = stale }
      expected = I18n.t("timesheet_entry.ownership_moving")
      with_request_id(tenant) do |request_id|
        moving, alerts = alerting do
          as_caller(tenant, request_id) { Timekeeping::Gateway::Remote.call(command, read_before) }
          nil
        rescue Timekeeping::Ownership::Moving => error
          error
        end
        unless moving&.message == expected
          fail! "#{tenant[:name]}: #{what} answered #{moving ? moving.message.inspect : 'success'}, not the retryable " \
                "ownership-moving #{expected.inspect}"
        end

        alerted!(tenant, what, alerts)
        moving
      end
    end

    # --- admitted: the retry of an update that went through -----------------

    def admitted(tenant, entry)
      id = entry.id
      edited = "#{entry.note} edited"
      command = Timekeeping::Gateway::UpdateEntry.new(
        entry:, project: tenant[:project], writer: "web",
        attributes: { duration: entry.duration, note: edited, work_date: Date.current.iso8601, bill_status: "unbilled" }
      )
      key = SecureRandom.uuid
      first = forward(tenant, command, generation: current, key:, request_id: SecureRandom.uuid).attributes
      after_update = owner_entry(tenant, id)
      fail! "#{tenant[:name]}: the update of entry #{id} under generation #{current} did not reach Timekeeping" unless after_update["note"] == edited

      refused!(tenant, "the retry of the update of entry #{id} carrying generation #{stale}") do |request_id|
        forward(tenant, command, generation: stale, key:, request_id:)
      end
      unchanged_entry!(tenant, id, after_update, "the refused retry of its update")

      stored!(tenant, command, key, first)
      unchanged_entry!(tenant, id, after_update, "the retry of its update under generation #{current}")
      entry.note = edited
      say "#{tenant[:name]}: the update of entry #{id} went through at version #{after_update['version']}; its " \
          "retry carrying generation #{stale} was refused, and its retry under #{current} was answered the stored " \
          "result, so it ran once"
    end

    # The retry of an admitted command, under the current generation and its
    # own key, answers what the command first answered.
    def stored!(tenant, command, key, first)
      again = forward(tenant, command, generation: current, key:, request_id: SecureRandom.uuid).attributes
      return if again == first

      fail! "#{tenant[:name]}: the retry of the update of entry #{command.entry.id} under generation #{current} answered " \
            "#{again}, not its stored result #{first}"
    end

    # --- reservations: prepare, commit and abort -----------------------------

    # `held` is on the draft; `added` is what the refused prepare and the
    # retried save add to it.
    def reservations(tenant, held, added)
      entries = [held, added]
      rate = candidate_rate(tenant, entries.map(&:id))
      draft_id = save_draft(tenant, held, rate)
      committed = delivered!(tenant, latest_intent(draft_id), "succeeded")
      held!(tenant, [held.id], offered: [added.id], after: "saving draft #{draft_id}")
      before = reservation_state(tenant, draft_id, entries)

      stale_prepare!(tenant, draft_id, entries)
      stale_deliveries!(tenant, committed)
      after = reservation_state(tenant, draft_id, entries)
      fail! "#{tenant[:name]}: the refused reservation calls changed #{before} into #{after}" unless after == before
      held!(tenant, [held.id], offered: [added.id], after: "the refused reservation calls")
      say "#{tenant[:name]}: a prepare adding entry #{added.id} to draft #{draft_id}, and a commit and an abort of its " \
          "committed operation #{committed.operation_id}, each carrying generation #{stale}, were refused; the commit " \
          "under #{current} was answered its stored receipt, and nothing changed"

      retried_save!(tenant, draft_id, added, rate)
      draft_id
    end

    # A prepare of the draft's next operation, which adds the last of
    # `entries`, carrying the old generation.
    def stale_prepare!(tenant, draft_id, entries)
      intent = Timekeeping::InvoiceOperation.new(
        operation_id: SecureRandom.uuid, invoice_id: draft_id, company_id: tenant[:company].id, kind: "save",
        entry_ids: entries.map(&:id), generation: stale, state: "pending"
      )
      refused!(tenant, "a prepare of draft #{draft_id} adding entry #{entries.last.id}, carrying generation #{stale}") do |request_id|
        NamedReservationClient.new(request_id:).prepare(intent, invoice_state: :draft, resolves: nil)
      end
    end

    # A commit and an abort of the committed operation carrying the old
    # generation, as a delivery queued before a handoff would; then the
    # commit under the current one, answered its stored receipt.
    def stale_deliveries!(tenant, committed)
      operation_id = committed.operation_id
      old = Timekeeping::InvoiceOperation.new(committed.attributes.except("id").merge("generation" => stale))
      %i[commit abort].each do |call|
        refused!(tenant, "the #{call} of operation #{operation_id} carrying generation #{stale}") do |request_id|
          NamedReservationClient.new(request_id:).public_send(call, old)
        end
      end
      status = Timekeeping::ReservationClient.new.commit(committed).status
      return if status == "committed"

      fail! "#{tenant[:name]}: the commit of operation #{operation_id} under generation #{current} answered #{status}, " \
            "not its stored committed receipt"
    end

    # The admin's own retry: the save, under the current generation.
    def retried_save!(tenant, draft_id, entry, rate)
      response = as(tenant, :admin).call(:patch, "/api/v1/invoices/#{draft_id}", body: { invoice: { invoice_line_items_attributes: [direct(entry, rate)] } })
      expect_ok!(response, "retry the save of draft #{draft_id} adding entry #{entry.id}")
      delivered!(tenant, latest_intent(draft_id), "succeeded")
      held!(tenant, [entry.id], offered: [], after: "the retried save of draft #{draft_id}")
      say "#{tenant[:name]}: the admin retried the save adding entry #{entry.id}, and draft #{draft_id} now holds it"
    end

    # --- calls ----------------------------------------------------------------

    def create_command(tenant, entry)
      Timekeeping::Gateway::CreateEntry.new(
        project: tenant[:project], user: User.find(tenant[:employee_id]), writer: "web",
        attributes: { duration: entry.duration, note: entry.note, work_date: Date.current.iso8601, bill_status: "unbilled" }
      )
    end

    # The command as the gateway sends it (Timekeeping::Gateway::Remote), with
    # the employee's claims, under `generation`, with `key`.
    def forward(tenant, command, generation:, key:, request_id:)
      request = Timekeeping::Gateway::Remote::REQUESTS.fetch(command.class).call(command)
      claims = Timekeeping::UserToken.caller_claims(
        user: User.find(tenant[:employee_id]), company: tenant[:company], writer: request.writer,
        project: request.project, request_id:
      )
      write = Timekeeping::EntryClient::Write.new(claims:, generation:, idempotency_key: key)
      request.forward.call(Timekeeping::EntryClient.new, write)
    end

    # Runs the call, which must raise the 409 stale-generation problem, not
    # retryable, and report the alert once.
    def refused!(tenant, what)
      with_request_id(tenant) do |request_id|
        refused, alerts = alerting do
          yield request_id
          nil
        rescue Timekeeping::InternalApi::Problem => problem
          problem
        end
        unless refused && refused.status == 409 && refused.type == "stale-generation" && !refused.retryable
          fail! "#{tenant[:name]}: #{what} answered #{refused ? refused.message : 'success'}, not 409 stale-generation"
        end

        alerted!(tenant, what, alerts)
        refused
      end
    end

    # A request id for the call the block makes. Once the block answers
    # without raising, the id is kept for the run's last line.
    def with_request_id(tenant)
      request_id = "#{@run}-#{tenant[:company].id}-#{@refused.size + 1}"
      yield(request_id).tap { @refused << request_id }
    end

    # What the block answers, and the stale-generation alerts the existing
    # application reported while it ran.
    def alerting
      alerts = Alerts.new
      Rails.error.subscribe(alerts)
      [yield, alerts.reported]
    ensure
      Rails.error.unsubscribe(alerts)
    end

    def alerted!(tenant, what, alerts)
      return if alerts.size == 1

      fail! "#{tenant[:name]}: #{what} reported #{alerts.size} stale-generation alerts here, not 1 (§11.3)"
    end

    # Current.user and the request id are what the gateway's claims read.
    def as_caller(tenant, request_id, &)
      saved = Rails.event.context.dup
      Rails.event.set_context(request_id:)
      Current.set(user: User.find(tenant[:employee_id]), company: tenant[:company], &)
    ensure
      Rails.event.clear_context
      Rails.event.set_context(saved) if saved.present?
    end

    def create_entry(tenant, letter)
      entry = Entry.new(duration: DURATIONS.fetch(letter), note: note(letter))
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: entry.duration, note: entry.note))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]}")
      entry.id = response.json.dig("entry", "id")
      entry
    end

    def save_draft(tenant, entry, rate)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number(tenant), status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: [direct(entry, rate)]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number(tenant)}")
      response.json.fetch("id")
    end

    def direct(entry, rate)
      { name: entry.note, date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
    end

    def clean_up(tenant, draft_id, entries)
      ids = entries.map(&:id)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      delivered!(tenant, latest_intent(draft_id), "succeeded", kind: "discard")
      held!(tenant, [], offered: ids, after: "deleting draft #{draft_id}")
      ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{ids} leave the entry list and the candidates") do
        listed = entry_list(tenant).keys + candidates(tenant).keys
        ids.none? { |id| listed.include?(id) }
      end
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entries #{ids}"
    end

    # --- checks ---------------------------------------------------------------

    def not_written!(tenant, entry, after:)
      held = owner_entries(tenant, entry).map { |row| row.fetch("id") }
      fail! "#{tenant[:name]}: after #{after}, Timekeeping holds entries #{held} noted #{entry.note.inspect}" if held.any?
    end

    def unchanged_entry!(tenant, id, before, after)
      now = owner_entry(tenant, id)
      return if now == before

      fail! "#{tenant[:name]}: #{after} changed entry #{id} on Timekeeping: #{before} became #{now}"
    end

    def held!(tenant, held, offered:, after:)
      eventually("after #{after}, the candidates of #{tenant[:name]} leave out entries #{held} and offer #{offered}") do
        shown = candidates(tenant)
        held.none? { |id| shown.key?(id) } && offered.all? { |id| shown.key?(id) }
      end
    end

    # Waits for the invoice operation worker to deliver the intent's commit or
    # abort, and checks what the save recorded.
    def delivered!(tenant, intent, state, kind: "save")
      unless intent.kind == kind && intent.state == state
        fail! "#{tenant[:name]}: the ledger's last operation of invoice #{intent.invoice_id} is #{intent.kind} #{intent.state}, " \
              "not #{kind} #{state}"
      end

      eventually("the invoice operation worker delivers operation #{intent.operation_id} of invoice #{intent.invoice_id}") do
        intent.reload.delivered_at
      end
      intent
    end

    # --- reads ----------------------------------------------------------------

    def latest_intent(invoice_id, kind: nil)
      scope = Timekeeping::InvoiceOperation.where(invoice_id:)
      scope = scope.where(kind:) if kind
      scope.order(:id).last || fail!("no operation of invoice #{invoice_id} in the invoice operation ledger")
    end

    def candidate_rate(tenant, ids)
      eventually("the candidates of #{tenant[:name]} offer entries #{ids}") do
        offered = candidates(tenant)
        offered[ids.first] if ids.all? { |id| offered.key?(id) }
      end.fetch("rate")
    end

    # What the refused reservation calls must leave as it was: the draft's rows
    # of the ledger, and each entry as Timekeeping holds it.
    def reservation_state(tenant, draft_id, entries)
      {
        ledger: Timekeeping::InvoiceOperation.where(invoice_id: draft_id).order(:id).map(&:attributes),
        entries: entries.map { |entry| owner_entry(tenant, entry.id) }
      }
    end

    # Timekeeping's own record of the entry (§5.2 show).
    def owner_entry(tenant, id)
      Timekeeping::EntryClient.new.show_entry(id, claims: system_claims(tenant))
        .slice("id", "note", "version", "locked", "updated_at")
    end

    # The employee's kept entries of today on Timekeeping noted as `entry` is.
    def owner_entries(tenant, entry)
      Timekeeping::EntryClient.new
        .list_entries(claims: system_claims(tenant), user_id: tenant[:employee_id], work_dates: Date.current..Date.current)
        .select { |row| row["note"] == entry.note }
    end

    def system_claims(tenant)
      Timekeeping::UserToken.system_claims(company: tenant[:company], writer: "invoice", request_id: SecureRandom.uuid)
    end
end
