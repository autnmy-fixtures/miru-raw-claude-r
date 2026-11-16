# frozen_string_literal: true

# The save-failure part of docs/architecture/timekeeping-soa.md §12.4's
# failure injection, against the two running applications of the local demo
# (§11.2): the rows of §9.3 where an invoice save fails, or is replayed, after
# its prepare reached the owner.
#
#   Lost response on prepare: Timekeeping prepares, and every answer is lost
#   on the way back. The save fails as retryable, its intent is recorded
#   `failed`, and the abort delivered from the ledger releases what the
#   prepare reserved.
#
#   Crash after prepare, before the invoice commits: the process is killed
#   inside the invoice transaction, after the invoice was written. The intent
#   is still `pending`, no invoice exists, and the entry stays held. Recovery
#   records `failed` once the save's time limit passes, and abort is
#   delivered.
#
#   Invoice transaction rolls back: a save whose invoice is invalid after its
#   prepare. The intent is recorded `failed`, and abort is delivered.
#
#   Prepare arrives after its operation is terminal, and prepare answers 200
#   with a terminal receipt (§9.2 step 3): replay a save whose operation is
#   `committed`, and the save returns the existing outcome and changes
#   nothing; replay one whose operation is `aborted`, and the save fails;
#   force the intent `pending` with the operation `committed`, and the save
#   fails with a retryable reconciliation error and no change.
#
# It runs while Timekeeping owns the entries with admission open, in one
# step, on each seeded business. The employee creates four entries over the
# public API (Timekeeping::PublicApi); A is saved on a draft by the admin, and
# B, C and D are each the one entry of a save that fails. A save goes over the
# public API where nothing has to be injected (the draft of A, the rolled-back
# save of B). The others run in this process, through the same invoice writes
# the controllers use (Timekeeping::InvoiceWrites), with the failure put
# between them and the owner:
#
#   - the lost responses by a provider that sends each prepare to Timekeeping
#     and then raises a read timeout instead of answering;
#   - the crash by a child process that runs the save and kills itself with
#     SIGKILL inside the invoice transaction, after the invoice was written;
#   - the replays by running the save's steps 2-4 again for an intent already
#     resolved (Timekeeping::InvoiceBoundary#perform), the way a resend of the
#     same operation does, with an invoice change that fails the check if it
#     runs. The forced `pending` lasts only inside a transaction this check
#     rolls back, so the invoice operation worker never sees it and recovery
#     never resolves it.
#
# "Changes nothing" is read on both sides: the invoice and its lines, the
# invoice's rows of the operation ledger, and, from Timekeeping, the entry's
# version and `locked`, which every reservation change moves (§5.4).
# Reservations are read as the invoice editor reads them, from the
# candidates, which offer an entry exactly when nothing reserves it. Any check
# that does not hold raises Failed. A run that finishes leaves, per business,
# four discarded entries and one discarded draft; one that fails leaves what
# it wrote for inspection.
class Timekeeping::SaveFailuresCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # The four entries of a run: A, on the committed draft; B, of the save that
  # rolls back; C, of the save whose prepare answers are lost; D, of the save
  # that crashes.
  DURATIONS = { "A" => 15.0, "B" => 25.0, "C" => 35.0, "D" => 45.0 }.freeze

  # Total prepare attempts of one save (§9.4).
  ATTEMPTS = Timekeeping::InvoiceBoundary::PREPARE_ATTEMPTS

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker (the crash's recovery waits for the save's time limit, 30 s, too);
  # tenants default to the seeded businesses; crash runs a save that kills
  # its own process, and defaults to a forked child (ForkedCrash).
  Options = Data.define(:wait, :tenants, :crash) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS, crash: ForkedCrash.new) = super
  end

  # Runs the save in a child process, handing it the crash: SIGKILL of that
  # child, which no handler, ensure or at_exit can intercept, so the child's
  # open invoice transaction ends the way a killed process's does. Answers
  # once the child is dead, and raises Failed unless the crash killed it.
  class ForkedCrash
    KILL = Signal.list.fetch("KILL")

    def call(&save)
      pid = Process.fork do
        save.call(-> { Process.kill(KILL, Process.pid) })
        warn "save failures: the save ended without crashing"
        exit!(3)
      rescue Exception => error # rubocop:disable Lint/RescueException -- the child must never run the parent's exit handlers
        warn "save failures: the save raised #{error.class}: #{error.message}"
        exit!(4)
      end
      _, status = Process.wait2(pid)
      return if status.signaled? && status.termsig == KILL

      raise Failed, "the save meant to crash ended with #{status.inspect}, not killed by SIGKILL"
    end
  end

  # A reservation provider (§5.3) whose prepare reaches the owner and runs
  # there, and whose answer is then lost: the caller sees a read timeout. It
  # keeps every answer it lost.
  class LostAnswers
    attr_reader :lost

    def initialize(provider)
      @provider = provider
      @lost = []
    end

    def prepare(...)
      @lost << @provider.prepare(...)
      raise Faraday::TimeoutError, "the answer to prepare was lost on the way back"
    end
  end

  # The invoice reservation boundary with a crash put inside the invoice
  # transaction: after the invoice change ran, before success is recorded and
  # the transaction commits.
  class CrashingBoundary
    def initialize(boundary, crash)
      @boundary, @crash = boundary, crash
    end

    def run(change, &change_block)
      @boundary.run(change) { |prepared| change_block.call(prepared).tap { @crash.call } }
    end
  end

  # What "changes nothing" is read from: the invoice and its lines, the
  # invoice's rows of the ledger, and the entry as its owner holds it.
  State = Data.define(:invoice, :lines, :ledger, :entry)

  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  def call
    @ownership = ensure_timekeeping_owns!
    @options.tenants.each { |tenant| check_tenant(prepare_tenant(tenant)) }
    say "a lost prepare answer, a crash after prepare, a rolled-back save and the replays of a committed, an aborted " \
        "and a forced-pending operation each left the invoice and its reservations as §9.3 says, on " \
        "#{@options.tenants.size} businesses, at generation #{@ownership.generation}"
  end

  private

    def log_prefix = "save failures"

    def wait = @options.wait

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the save-failures proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(letter) = "Save failures #{@run} #{letter}"

    def number(tenant, suffix = nil) = ["SVF-#{tenant[:company].id}-#{@run}", suffix].compact.join("-")

    def check_tenant(tenant)
      entries = DURATIONS.to_h { |letter, duration| [letter, create_entry(tenant, letter, duration)] }
      rate = candidate_rate(tenant, entries.values.map(&:id))

      draft_id, committed = committed_draft(tenant, entries.fetch("A"), rate)
      replay_committed(tenant, draft_id, committed)
      replay_forced_pending(tenant, draft_id, committed)
      aborted = rolled_back(tenant, entries.fetch("B"), rate)
      replay_aborted(tenant, aborted)
      lost_prepare(tenant, entries.fetch("C"), rate)
      crash(tenant, entries.fetch("D"), rate)

      clean_up(tenant, draft_id, entries.values.map(&:id))
    end

    # --- the committed draft, and its replays ----------------------------

    def committed_draft(tenant, entry, rate)
      response = save_over_api(tenant, number(tenant), [direct(entry, rate)])
      expect_ok!(response, "save the draft #{number(tenant)}")
      draft_id = response.json.fetch("id")
      committed = intent_of(tenant, entry.id)
      fail! "#{tenant[:name]}: the save of draft #{draft_id} left its intent #{committed.state}, not succeeded" unless committed.state_succeeded?

      delivered!(tenant, committed)
      expect_reserved_ids!(tenant, held: [entry.id], offered: [], after: "saving draft #{draft_id}")
      say "#{tenant[:name]}: draft #{draft_id} holds entry #{entry.id}, and its commit was delivered"
      [draft_id, committed]
    end

    # Prepare arrives after its operation is terminal: the owner answers its
    # committed receipt, and the save returns the existing outcome.
    def replay_committed(tenant, draft_id, committed)
      before = state_of(tenant, draft_id, committed)
      result = replay(committed)
      fail! "#{tenant[:name]}: the replay of committed operation #{committed.operation_id} did not answer as a replay" unless result.replayed

      unchanged!(tenant, before, state_of(tenant, draft_id, committed), "replaying committed operation #{committed.operation_id}")
      say "#{tenant[:name]}: a replay of committed operation #{committed.operation_id} was answered its receipt and " \
          "returned the existing outcome; draft #{draft_id} and entry #{before.entry.fetch('id')} are unchanged"
    end

    # The intent forced pending while the owner holds the operation committed.
    # Rolled back before anyone else can read it.
    def replay_forced_pending(tenant, draft_id, committed)
      before = state_of(tenant, draft_id, committed)
      failure = nil
      Timekeeping::InvoiceOperation.transaction(joinable: false) do
        committed.update_columns(state: "pending", delivered_at: nil)
        failure = replay_failure(tenant, committed, "forced pending")
        raise ActiveRecord::Rollback
      end
      committed.reload

      unless failure.reason == :unreconciled && failure.retryable
        fail! "#{tenant[:name]}: the replay of operation #{committed.operation_id}, forced pending, failed as " \
              "#{failure.reason} (retryable: #{failure.retryable}), not a retryable reconciliation error"
      end
      unchanged!(tenant, before, state_of(tenant, draft_id, committed), "replaying operation #{committed.operation_id} forced pending")
      say "#{tenant[:name]}: a replay of operation #{committed.operation_id}, forced pending while committed at its owner, " \
          "failed with a retryable reconciliation error and changed nothing"
    end

    # --- the rolled-back save, and its replay ---------------------------

    # The draft's number is taken, so the invoice fails its validation inside
    # the invoice transaction, after its prepare reserved entry B.
    def rolled_back(tenant, entry, rate)
      response = save_over_api(tenant, number(tenant), [direct(entry, rate)])
      expected = "Invoice number has already been taken"
      unless response.status == 422 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: a save reusing the number #{number(tenant)} answered #{response.status} " \
              "#{response.body.to_s.truncate(500)}, not 422 #{expected.inspect}"
      end

      aborted = intent_of(tenant, entry.id)
      failed_and_aborted!(tenant, aborted, entry, "the rolled-back save")
      say "#{tenant[:name]}: a save that rolled back after its prepare recorded operation #{aborted.operation_id} failed, " \
          "wrote no invoice, and its abort released entry #{entry.id}"
      aborted
    end

    # A replay of an operation its owner holds as aborted fails.
    def replay_aborted(tenant, aborted)
      before = state_of(tenant, aborted.invoice_id, aborted)
      failure = replay_failure(tenant, aborted, "aborted")
      unless failure.reason == :aborted && !failure.retryable
        fail! "#{tenant[:name]}: the replay of aborted operation #{aborted.operation_id} failed as #{failure.reason} " \
              "(retryable: #{failure.retryable}), not as aborted"
      end

      unchanged!(tenant, before, state_of(tenant, aborted.invoice_id, aborted), "replaying aborted operation #{aborted.operation_id}")
      say "#{tenant[:name]}: a replay of aborted operation #{aborted.operation_id} failed and changed nothing"
    end

    # --- the lost answers, and the crash --------------------------------

    def lost_prepare(tenant, entry, rate)
      lost = LostAnswers.new(Timekeeping::ReservationClient.new)
      boundary = Timekeeping::InvoiceBoundary.new(providers: { "timekeeping" => -> { lost } })
      failure = begin
        create_in_process(tenant, Timekeeping::InvoiceWrites.new(boundary:), number(tenant, "C"), entry, rate)
        fail! "#{tenant[:name]}: the save whose prepare answers were all lost went through"
      rescue Timekeeping::InvoiceBoundary::Failed => error
        error
      end

      unless failure.reason == :unavailable && failure.retryable
        fail! "#{tenant[:name]}: the save whose prepare answers were lost failed as #{failure.reason}, not as a retryable unavailable"
      end
      unless lost.lost.size == ATTEMPTS && lost.lost.all? { |answer| answer.try(:entries)&.map(&:id) == [entry.id] }
        fail! "#{tenant[:name]}: Timekeeping answered the lost prepares #{lost.lost.inspect.truncate(500)}, " \
              "not #{ATTEMPTS} times prepared with entry #{entry.id}"
      end

      intent = intent_of(tenant, entry.id)
      failed_and_aborted!(tenant, intent, entry, "the save whose prepare answers were lost")
      say "#{tenant[:name]}: Timekeeping prepared operation #{intent.operation_id} #{ATTEMPTS} times and every answer was lost; " \
          "the save failed as retryable, recorded the intent failed, and its abort released entry #{entry.id}"
    end

    def crash(tenant, entry, rate)
      @options.crash.call do |kill|
        writes = Timekeeping::InvoiceWrites.new(boundary: CrashingBoundary.new(Timekeeping::InvoiceBoundary.new, kill))
        create_in_process(tenant, writes, number(tenant, "D"), entry, rate)
      end

      intent = intent_of(tenant, entry.id)
      fail! "#{tenant[:name]}: after the crash, operation #{intent.operation_id} is #{intent.state}, not pending" unless intent.state_pending?
      no_invoice!(tenant, intent, "the crashed save")
      expect_reserved_ids!(tenant, held: [entry.id], offered: [], after: "the crash of operation #{intent.operation_id}")
      say "#{tenant[:name]}: the process was killed after prepare, inside the invoice transaction: operation " \
          "#{intent.operation_id} is still pending, there is no invoice #{intent.invoice_id}, and entry #{entry.id} stays held"

      started = monotonic
      failed_and_aborted!(tenant, intent, entry, "the crashed save")
      say "#{tenant[:name]}: recovery recorded operation #{intent.operation_id} failed and its abort released entry " \
          "#{entry.id}, #{(monotonic - started).round} s later"
    end

    # --- the checks -------------------------------------------------------

    # Recorded failed, by the save or by recovery, with its abort delivered
    # and the entry offered again; and no invoice was written.
    def failed_and_aborted!(tenant, intent, entry, what)
      eventually("#{what}'s operation #{intent.operation_id} is recorded failed, its abort is delivered, " \
                 "and the candidates offer entry #{entry.id} again") do
        offered = candidates(tenant).key?(entry.id)
        intent.reload
        offered && intent.state_failed? && intent.delivered_at.present?
      end
      no_invoice!(tenant, intent, what)
    end

    def delivered!(tenant, intent)
      eventually("the invoice operation worker delivers operation #{intent.operation_id} for #{tenant[:name]}") do
        intent.reload.delivered_at.present?
      end
    end

    def no_invoice!(tenant, intent, what)
      return unless Invoice.with_discarded.exists?(intent.invoice_id)

      fail! "#{tenant[:name]}: #{what} left invoice #{intent.invoice_id}, which should never have committed"
    end

    def unchanged!(tenant, before, after, what)
      changed = before.to_h.reject { |key, value| after.public_send(key) == value }.keys
      return if changed.empty?

      fail! "#{tenant[:name]}: #{what} changed #{changed.join(', ')}: #{before.to_h.slice(*changed)} became " \
            "#{after.to_h.slice(*changed)}"
    end

    def state_of(tenant, invoice_id, intent)
      invoice = Invoice.with_discarded.find_by(id: invoice_id)
      State.new(
        invoice: invoice&.attributes,
        lines: invoice ? invoice.invoice_line_items.order(:id).map(&:attributes) : [],
        ledger: Timekeeping::InvoiceOperation.where(invoice_id:).order(:id).map(&:attributes),
        entry: owner_entry(tenant, intent.entry_ids.sole).slice("id", "version", "locked", "updated_at")
      )
    end

    # Timekeeping's own record of the entry (§5.2 show).
    def owner_entry(tenant, id)
      claims = Timekeeping::UserToken.system_claims(company: tenant[:company], writer: "invoice", request_id: SecureRandom.uuid)
      Timekeeping::EntryClient.new.show_entry(id, claims:)
    end

    def expect_reserved_ids!(tenant, held:, offered:, after:)
      eventually("after #{after}, the candidates leave out entries #{held} and offer #{offered}") do
        shown = candidates(tenant)
        held.none? { |id| shown.key?(id) } && offered.all? { |id| shown.key?(id) }
      end
    end

    # --- the saves ----------------------------------------------------------

    # The save's steps 2-4 run again for its intent: the owner is asked to
    # prepare the same operation again. The invoice change must never run.
    def replay(intent)
      Timekeeping::InvoiceBoundary.new.perform(intent, invoice_state: :draft) do
        fail! "the replay of operation #{intent.operation_id} ran the invoice change again"
      end
    end

    def replay_failure(tenant, intent, what)
      replay(intent)
      fail! "#{tenant[:name]}: the replay of #{what} operation #{intent.operation_id} went through"
    rescue Timekeeping::InvoiceBoundary::Failed => error
      error
    end

    # The save of one invoice holding entry under the latest operation that
    # names it. Each entry of a run is the one entry of its own saves.
    def intent_of(tenant, entry_id)
      Timekeeping::InvoiceOperation.where(company_id: tenant[:company].id, kind: "save")
        .where("? = ANY(entry_ids)", entry_id).order(:id).last ||
        fail!("#{tenant[:name]}: no save of entry #{entry_id} in the invoice operation ledger")
    end

    def save_over_api(tenant, invoice_number, lines)
      as(tenant, :admin).call(:post, "/api/v1/invoices", body: { invoice: invoice_attributes(tenant, invoice_number, lines) })
    end

    def create_in_process(tenant, writes, invoice_number, entry, rate)
      attributes = invoice_attributes(tenant, invoice_number, [direct(entry, rate)]).deep_stringify_keys
      writes.create(tenant[:company], attributes)
    end

    def invoice_attributes(tenant, invoice_number, lines)
      {
        client_id: tenant[:project].client_id, invoice_number:, status: "draft",
        issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
        currency: tenant[:company].base_currency, invoice_line_items_attributes: lines
      }
    end

    def direct(entry, rate)
      { name: "Save failures #{entry.note.split.last}", date: Date.current.iso8601, timesheet_entry_id: entry.id,
        quantity: entry.duration, rate: }
    end

    def create_entry(tenant, letter, duration)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note: note(letter)))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note: note(letter))
    end

    # The rate the invoice editor offers, once it offers every entry.
    def candidate_rate(tenant, ids)
      eventually("the candidates offer entries #{ids}") do
        offered = candidates(tenant)
        offered[ids.first] if ids.all? { |id| offered.key?(id) }
      end.fetch("rate")
    end

    def clean_up(tenant, draft_id, entry_ids)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      expect_reserved_ids!(tenant, held: [], offered: entry_ids, after: "deleting draft #{draft_id}")
      entry_ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{entry_ids} leave the entry list and the candidates") do
        listed = entry_list(tenant).keys + candidates(tenant).keys
        entry_ids.none? { |id| listed.include?(id) }
      end
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entries #{entry_ids}"
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
