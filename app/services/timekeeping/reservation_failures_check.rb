# frozen_string_literal: true

# The reservation-protocol part of docs/architecture/timekeeping-soa.md
# §12.4's failure injection, against the two running applications of the
# local demo (§11.2): the rows of §9.3 where Timekeeping refuses a prepare,
# or loses the answer to a commit.
#
#   Prepare refused (wrong company): a save naming another business's entry
#   fails with today's 422 shape and a clear reason, and nothing is reserved.
#
#   Prepare refused, earlier operation unresolved: Timekeeping still holds an
#   earlier operation of the invoice prepared, and the new prepare does not
#   carry that operation's outcome. The save fails with a retryable 409.
#   Recovery resolves it (the invoice operation worker delivers the earlier
#   outcome), and the client's retry then goes through.
#
#   Lost response on commit: Timekeeping commits, and the answer is lost on
#   the way back. The intent stays `succeeded` and undelivered, the worker
#   sends commit again, and the commit is idempotent: the entry is unchanged.
#
# It runs while Timekeeping owns the entries with admission open, in two
# steps around a stopped invoice operation worker. bin/timekeeping-demo
# reservation-failures stops miru-jobs, runs #paused, starts miru-jobs again
# and runs #resumed. Both steps name their writes after the same run, and
# #paused leaves what #resumed needs in the run's state file. On each seeded
# business, over the public API as its users (Timekeeping::PublicApi), except
# where a failure has to be put between the existing application and
# Timekeeping:
#
#   paused   the employee creates entries X, Y and W. The admin saves an
#            invoice naming the other business's W: 422, the wrong-company
#            message, no invoice, and W unchanged and still offered there.
#            The admin saves a draft holding X: its intent succeeds, and its
#            commit stays undelivered, Timekeeping holding the operation
#            prepared. An update adding Y, run in process with Timekeeping
#            unreachable, fails before its prepare is sent. Two more updates
#            adding Y, one in process and one over the public API, each
#            carry in `resolves` the outcome of the update before it, which
#            Timekeeping never held, and not the draft's, so Timekeeping
#            refuses each as operation-unresolved:
#            the in-process one fails as a retryable operation_unresolved,
#            and the public one answers 409. The draft still holds X alone,
#            and Y is still offered. Then one sweep of the invoice operation
#            worker runs in process through an owner that sends every commit
#            and abort to Timekeeping and loses each answer: the draft's
#            commit is answered `committed`, every abort `aborted`, and all
#            of them stay undelivered. Timekeeping's record of X as the
#            commit left it is kept in the state file.
#   resumed  miru-jobs delivers every operation of the run: commit again for
#            the draft, abort for each failed save. X is unchanged on
#            Timekeeping (version, `locked`, `updated_at`), so the second
#            commit changed nothing. The draft still holds X alone. The
#            client retries the update adding Y over the public API, and it
#            goes through: the draft holds X and Y, and its commit is
#            delivered. Then the draft is deleted and the entries discarded.
#
# If the draft's commit is delivered during the paused step, the worker was
# running and the run fails: it would prove nothing. Any check that does not
# hold raises Failed. A run that finishes leaves, per business, three
# discarded entries and one discarded draft; one that fails leaves what it
# wrote for inspection.
class Timekeeping::ReservationFailuresCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # The three entries of a run: X, on the draft; Y, which the draft's updates
  # add; W, which the other business's save names.
  DURATIONS = { "X" => 20.0, "Y" => 30.0, "W" => 40.0 }.freeze

  # Where the runs keep their state, under the application root: in the demo,
  # the miru_handoff_journals volume, so both steps' processes see it.
  DIRECTORY = "tmp/timekeeping/reservation-failures"

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses, and must be two or
  # more; directory is where the runs keep their state.
  Options = Data.define(:wait, :tenants, :directory) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS, directory: DIRECTORY) = super
  end

  # A reservation provider (§5.3) behind which Timekeeping cannot be reached:
  # nothing is sent.
  class Unreachable
    def prepare(*, **)
      raise Faraday::ConnectionFailed, "Timekeeping could not be reached"
    end
  end

  # An owner for the invoice operation worker whose commit and abort reach
  # Timekeeping and run there, and whose answers are then lost: the worker
  # sees a read timeout. It keeps every answer it lost, by operation id.
  class LostDeliveries
    attr_reader :lost

    def initialize(owner)
      @owner = owner
      @lost = {}
    end

    def commit(intent) = lose(:commit, intent)

    def abort(intent) = lose(:abort, intent)

    private

      def lose(call, intent)
        @lost[intent.operation_id] = [call, @owner.public_send(call, intent).status]
        raise Faraday::TimeoutError, "the answer to #{call} was lost on the way back"
      end
  end

  # run: names the writes of one run, the same for both steps.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # While the invoice operation worker (miru-jobs) is stopped.
  def paused
    ownership = ensure_timekeeping_owns!
    fail! "the reservation-failures proof needs two businesses, one to name the other's entry" if @options.tenants.size < 2

    tenants = @options.tenants.map { |tenant| prepare_tenant(tenant) }
    tenants.each { |tenant| tenant[:run] = create_entries(tenant) }
    tenants.each_with_index { |tenant, index| check_paused(tenant, tenants[(index + 1) % tenants.size]) }
    lost_commits(tenants)
    write_state(tenants)
    say "with the invoice operation worker stopped, a wrong-company save was refused, two saves behind an unresolved " \
        "operation were refused as retryable, and every commit and abort answer was lost, on #{tenants.size} " \
        "businesses, at generation #{ownership.generation}"
  end

  # Once the invoice operation worker runs again.
  def resumed
    ownership = ensure_timekeeping_owns!
    state = read_state
    @options.tenants.each do |tenant|
      check_resumed(prepare_tenant(tenant), state.fetch(tenant[:name]) { fail!("#{tenant[:name]}: no paused step of run #{@run} here") })
    end
    say "once the invoice operation worker resumed, every outcome was delivered, the commit sent again changed nothing, " \
        "and the retried save went through, on #{@options.tenants.size} businesses, at generation #{ownership.generation}"
  end

  private

    def log_prefix = "reservation failures"

    def wait = @options.wait

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the reservation-failures proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(letter) = "Reservation failures #{@run} #{letter}"

    def number(tenant, suffix = nil) = ["RSF-#{tenant[:company].id}-#{@run}", suffix].compact.join("-")

    # --- the paused step --------------------------------------------------

    def create_entries(tenant)
      entries = DURATIONS.to_h { |letter, duration| [letter, create_entry(tenant, letter, duration)] }
      ids = entries.values.map(&:id)
      rate = eventually("the candidates of #{tenant[:name]} offer entries #{ids}") do
        offered = candidates(tenant)
        offered[ids.first] if ids.all? { |id| offered.key?(id) }
      end.fetch("rate")
      { entries:, rate: }
    end

    def check_paused(tenant, other)
      wrong_company(tenant, other)
      draft_id, committed = save_draft(tenant)
      unreachable = update_unreachable(tenant, draft_id)
      in_process = unresolved_in_process(tenant, draft_id, unreachable)
      refused = [in_process, unresolved_over_api(tenant, draft_id, in_process)]
      worker_stopped!(tenant, committed)
      tenant[:run].merge!(draft_id:, committed:, failed: [unreachable, *refused])
    end

    # Prepare refused, wrong company (L8): the other business's entry W.
    def wrong_company(tenant, other)
      foreign = other[:run][:entries].fetch("W")
      id = foreign.id
      before = owner_entry(other, id)
      response = save_over_api(tenant, number(tenant, "W"), [direct(foreign, tenant[:run][:rate])])
      expected = I18n.t("invoices.reservation.refused.wrong_company", entry_id: id)
      unless response.status == 422 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: a save naming #{other[:name]}'s entry #{id} answered #{response.status} " \
              "#{response.body.to_s.truncate(500)}, not 422 #{expected.inspect}"
      end

      intent = latest_intent(company_id: tenant[:company].id, entry_id: id)
      fail! "#{tenant[:name]}: the wrong-company save left operation #{intent.operation_id} #{intent.state}, not failed" unless intent.state_failed?
      no_invoice!(tenant, intent, "the wrong-company save")
      unchanged_entry!(other, id, before, "#{tenant[:name]}'s wrong-company save")
      fail! "#{other[:name]}: the candidates no longer offer entry #{id}" unless candidates(other).key?(id)

      tenant[:run][:wrong_company] = intent
      say "#{tenant[:name]}: a save naming #{other[:name]}'s entry #{id} was refused with 422 #{expected.inspect}; " \
          "operation #{intent.operation_id} failed, no invoice was written, and the entry is unchanged"
    end

    # The draft's commit is never delivered while the worker is stopped, so
    # Timekeeping keeps its operation prepared.
    def save_draft(tenant)
      entry = tenant[:run][:entries].fetch("X")
      response = save_over_api(tenant, number(tenant), [direct(entry, tenant[:run][:rate])])
      expect_ok!(response, "save the draft #{number(tenant)}")
      draft_id = response.json.fetch("id")
      committed = latest_intent(invoice_id: draft_id)
      fail! "#{tenant[:name]}: the save of draft #{draft_id} left operation #{committed.operation_id} #{committed.state}, not succeeded" unless committed.state_succeeded?

      worker_stopped!(tenant, committed)
      eventually("the candidates of #{tenant[:name]} leave out entry #{entry.id}, held by draft #{draft_id}") { !candidates(tenant).key?(entry.id) }

      say "#{tenant[:name]}: draft #{draft_id} holds entry #{entry.id}; its commit of operation #{committed.operation_id} is not delivered"
      [draft_id, committed]
    end

    # An update whose prepare never reaches Timekeeping: recorded failed, and
    # its abort queued behind the draft's commit.
    def update_unreachable(tenant, draft_id)
      writes = Timekeeping::InvoiceWrites.new(boundary: Timekeeping::InvoiceBoundary.new(providers: { "timekeeping" => -> { Unreachable.new } }))
      failure = update_failure(tenant, writes, draft_id, "with Timekeeping unreachable")
      unless failure.reason == :unavailable && failure.retryable
        fail! "#{tenant[:name]}: the update of draft #{draft_id} with Timekeeping unreachable failed as #{failure.reason}, not as a retryable unavailable"
      end

      intent = failed_update!(tenant, draft_id, "with Timekeeping unreachable")
      say "#{tenant[:name]}: an update of draft #{draft_id} could not reach Timekeeping; operation #{intent.operation_id} " \
          "failed before its prepare was sent"
      intent
    end

    def unresolved_in_process(tenant, draft_id, unreachable)
      failure = update_failure(tenant, Timekeeping::InvoiceWrites.new, draft_id, "behind the unresolved operation")
      unless failure.reason == :operation_unresolved && failure.retryable
        fail! "#{tenant[:name]}: the update of draft #{draft_id} behind an unresolved operation failed as " \
              "#{failure.reason} (retryable: #{failure.retryable}), not as a retryable operation_unresolved"
      end

      intent = failed_update!(tenant, draft_id, "behind the unresolved operation")
      resolves!(tenant, intent, unreachable)
      say "#{tenant[:name]}: an update of draft #{draft_id} carried unreachable operation #{unreachable.operation_id}'s outcome while " \
          "Timekeeping holds the draft's operation prepared, and was refused as a retryable operation-unresolved"
      intent
    end

    def unresolved_over_api(tenant, draft_id, previous)
      response = update_over_api(tenant, draft_id)
      expected = I18n.t("invoices.reservation.busy")
      unless response.status == 409 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: the public update of draft #{draft_id} behind an unresolved operation answered " \
              "#{response.status} #{response.body.to_s.truncate(500)}, not 409 #{expected.inspect}"
      end

      intent = failed_update!(tenant, draft_id, "over the public API behind the unresolved operation")
      resolves!(tenant, intent, previous)
      say "#{tenant[:name]}: the same update over the public API answered 409 #{expected.inspect}; operation " \
          "#{intent.operation_id} failed, and draft #{draft_id} still holds entry #{tenant[:run][:entries].fetch('X').id} alone"
      intent
    end

    # Each refused update carried the outcome of the update before it, the
    # latest undelivered one, which Timekeeping never held: the unreachable
    # one, then the one refused before.
    def resolves!(tenant, intent, previous)
      expected = { "operation_id" => previous.operation_id, "outcome" => "aborted" }
      return if intent.resolves == expected

      fail! "#{tenant[:name]}: operation #{intent.operation_id} carries #{intent.resolves.inspect}, not #{expected.inspect}"
    end

    def worker_stopped!(tenant, committed)
      return unless committed.reload.delivered_at

      fail! "#{tenant[:name]}: the draft's commit of operation #{committed.operation_id} was delivered during the paused " \
            "step, so the invoice operation worker runs; stop miru-jobs first"
    end

    # One sweep of the invoice operation worker, every answer lost.
    def lost_commits(tenants)
      lost = LostDeliveries.new(Timekeeping::ReservationClient.new)
      result = Timekeeping::InvoiceOperationWorker.new(owners: { "timekeeping" => -> { lost } }).run
      tenants.each do |tenant|
        run = tenant[:run]
        expect_lost!(tenant, lost, result, run[:committed], [:commit, "committed"])
        [run[:wrong_company], *run[:failed]].each { |intent| expect_lost!(tenant, lost, result, intent, [:abort, "aborted"]) }
        run[:entry] = owner_entry(tenant, run[:entries].fetch("X").id).slice("id", "version", "locked", "updated_at")
        say "#{tenant[:name]}: Timekeeping committed operation #{run[:committed].operation_id} and aborted " \
            "#{run[:failed].size + 1} failed ones, and every answer was lost; all of them stay undelivered"
      end
    end

    def expect_lost!(tenant, lost, result, intent, answered)
      id = intent.operation_id
      call = answered.first
      if lost.lost[id] != answered
        fail! "#{tenant[:name]}: the sweep's #{call} of operation #{id} was answered #{lost.lost[id].inspect}, not #{answered.inspect}"
      end
      return if result.undelivered.include?(id) && intent.reload.delivered_at.nil?

      fail! "#{tenant[:name]}: operation #{id} was marked delivered though the answer to its #{call} was lost"
    end

    # --- the resumed step -------------------------------------------------

    def check_resumed(tenant, state)
      draft_id = state.fetch("draft_id")
      entries = state.fetch("entries").transform_values { |row| Entry.new(**row.symbolize_keys) }
      redelivered(tenant, state, draft_id, entries)
      retried(tenant, draft_id, entries, state.fetch("rate"))
      clean_up(tenant, draft_id, entries.values.map(&:id))
    end

    # Recovery: miru-jobs delivers every outcome the paused step left.
    def redelivered(tenant, state, draft_id, entries)
      intents = Timekeeping::InvoiceOperation.where(operation_id: state.fetch("operations").values).index_by(&:operation_id)
      eventually("miru-jobs delivers every operation of run #{@run} for #{tenant[:name]}") do
        intents.values.each(&:reload).all?(&:delivered_at)
      end
      delivered_as_recorded!(tenant, intents, state.fetch("operations"))
      unchanged_entry!(tenant, entries.fetch("X").id, state.fetch("entry"), "the commit sent again")
      held!(tenant, draft_id, [entries.fetch("X").id], "the commit sent again")
      offered = entries.values_at("Y", "W").map(&:id)
      eventually("the candidates of #{tenant[:name]} offer entries #{offered}") { offered.all? { |id| candidates(tenant).key?(id) } }
      say "#{tenant[:name]}: miru-jobs delivered the commit of operation #{state.dig('operations', 'committed')} again and " \
          "every abort; entry #{entries.fetch('X').id} is unchanged, so the second commit changed nothing"
    end

    def delivered_as_recorded!(tenant, intents, operations)
      operations.each do |role, operation_id|
        intent = intents.fetch(operation_id) { fail!("#{tenant[:name]}: operation #{operation_id} is not in the ledger") }
        expected = role == "committed" ? "succeeded" : "failed"
        next if intent.state == expected

        fail! "#{tenant[:name]}: operation #{operation_id} (#{role}) is #{intent.state}, not #{expected}"
      end
    end

    # The client retries once recovery resolved the earlier operation.
    def retried(tenant, draft_id, entries, rate)
      response = update_over_api(tenant, draft_id, rate:, entry: entries.fetch("Y"))
      expect_ok!(response, "retry the update of draft #{draft_id}")
      intent = latest_intent(invoice_id: draft_id)
      fail! "#{tenant[:name]}: the retried update left operation #{intent.operation_id} #{intent.state}, not succeeded" unless intent.state_succeeded?

      ids = entries.values_at("X", "Y").map(&:id)
      held!(tenant, draft_id, ids.sort, "the retried update")
      eventually("the retried update's commit of operation #{intent.operation_id} is delivered") { intent.reload.delivered_at }
      eventually("the candidates of #{tenant[:name]} leave out entries #{ids}, held by draft #{draft_id}") do
        candidates(tenant).keys.intersection(ids).empty?
      end
      say "#{tenant[:name]}: the client retried the update, and draft #{draft_id} now holds entries #{ids}"
    end

    def clean_up(tenant, draft_id, entry_ids)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("deleting draft #{draft_id} releases entries #{entry_ids}") { entry_ids.all? { |id| candidates(tenant).key?(id) } }
      entry_ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{entry_ids} leave the entry list and the candidates") do
        listed = entry_list(tenant).keys + candidates(tenant).keys
        entry_ids.none? { |id| listed.include?(id) }
      end
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entries #{entry_ids}"
    end

    # --- the checks -------------------------------------------------------

    def failed_update!(tenant, draft_id, what)
      intent = latest_intent(invoice_id: draft_id)
      expected = tenant[:run][:entries].values_at("X", "Y").map(&:id).sort
      unless intent.state_failed? && intent.delivered_at.nil? && intent.entry_ids.sort == expected
        fail! "#{tenant[:name]}: the update of draft #{draft_id} #{what} left operation #{intent.operation_id} " \
              "#{intent.state} for entries #{intent.entry_ids}, not failed and undelivered for #{expected}"
      end
      held!(tenant, draft_id, [tenant[:run][:entries].fetch("X").id], "the update #{what}")
      y = tenant[:run][:entries].fetch("Y").id
      fail! "#{tenant[:name]}: after the update #{what}, the candidates no longer offer entry #{y}" unless candidates(tenant).key?(y)

      intent
    end

    # The entries the draft's lines reference.
    def held!(tenant, draft_id, ids, after)
      held = Timekeeping::InvoiceDesiredSet.referenced(Invoice.find(draft_id))
      return if held == ids

      fail! "#{tenant[:name]}: after #{after}, draft #{draft_id} references entries #{held}, not #{ids}"
    end

    def no_invoice!(tenant, intent, what)
      return unless Invoice.with_discarded.exists?(intent.invoice_id)

      fail! "#{tenant[:name]}: #{what} left invoice #{intent.invoice_id}, which should never have committed"
    end

    def unchanged_entry!(tenant, id, before, after)
      now = owner_entry(tenant, id).slice(*before.keys)
      return if JSON.parse(JSON.generate(now)) == JSON.parse(JSON.generate(before))

      fail! "#{tenant[:name]}: #{after} changed entry #{id} on Timekeeping: #{before} became #{now}"
    end

    # Timekeeping's own record of the entry (§5.2 show).
    def owner_entry(tenant, id)
      claims = Timekeeping::UserToken.system_claims(company: tenant[:company], writer: "invoice", request_id: SecureRandom.uuid)
      Timekeeping::EntryClient.new.show_entry(id, claims:).slice("id", "version", "locked", "updated_at")
    end

    def latest_intent(company_id: nil, entry_id: nil, invoice_id: nil)
      scope = Timekeeping::InvoiceOperation.where(kind: "save")
      scope = scope.where(company_id:).where("? = ANY(entry_ids)", entry_id) if entry_id
      scope = scope.where(invoice_id:) if invoice_id
      scope.order(:id).last || fail!("no save of #{entry_id ? "entry #{entry_id}" : "invoice #{invoice_id}"} in the invoice operation ledger")
    end

    # --- the saves ----------------------------------------------------------

    def update_failure(tenant, writes, draft_id, what)
      writes.update(Invoice.find(draft_id), { Timekeeping::InvoiceWrites::LINES => [direct_y(tenant)] })
      fail! "#{tenant[:name]}: the update of draft #{draft_id} #{what} went through"
    rescue Timekeeping::InvoiceBoundary::Failed => error
      error
    end

    def update_over_api(tenant, draft_id, rate: tenant[:run][:rate], entry: tenant[:run][:entries].fetch("Y"))
      as(tenant, :admin).call(:patch, "/api/v1/invoices/#{draft_id}", body: { invoice: { invoice_line_items_attributes: [direct(entry, rate)] } })
    end

    def direct_y(tenant) = direct(tenant[:run][:entries].fetch("Y"), tenant[:run][:rate]).stringify_keys

    def save_over_api(tenant, invoice_number, lines)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number:, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: lines
        }
      }
      as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
    end

    def direct(entry, rate)
      { name: "Reservation failures #{entry.note.split.last}", date: Date.current.iso8601, timesheet_entry_id: entry.id,
        quantity: entry.duration, rate: }
    end

    def create_entry(tenant, letter, duration)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note: note(letter)))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note: note(letter))
    end

    # --- the run's state ----------------------------------------------------

    def state_path = Rails.root.join(@options.directory, @run, "state.json")

    def write_state(tenants)
      state = tenants.to_h do |tenant|
        run = tenant[:run]
        operations = { "committed" => run[:committed].operation_id, "wrong_company" => run[:wrong_company].operation_id }
          .merge(%w[unreachable unresolved_in_process unresolved_over_api].zip(run[:failed].map(&:operation_id)).to_h)
        [tenant[:name], {
          "draft_id" => run[:draft_id], "rate" => run[:rate], "operations" => operations, "entry" => run[:entry],
          "entries" => run[:entries].transform_values(&:to_h)
        }]
      end
      state_path.dirname.mkpath
      state_path.write(JSON.generate(state))
    end

    def read_state
      fail! "no paused step for run #{@run} (#{state_path}); run the paused step first" unless state_path.exist?

      JSON.parse(state_path.read)
    end
end
