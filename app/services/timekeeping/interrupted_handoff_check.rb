# frozen_string_literal: true

# The interrupted-and-resumed-handoff proof of docs/architecture/
# timekeeping-soa.md §13 item 6 (§10.5: "The procedure has the same shape in
# both directions and can resume from the step that failed", and "The
# outgoing owner stays fenced from step 1 through the flip, including through
# copy, reconciliation, an interruption and a resume"), against the two
# running applications of the local demo (§11.2).
#
# It runs under any owner with admission open, and interrupts the handoff
# that owner hands over with (HANDOFFS) twice before it lets it finish: the
# first cutover from `legacy`, the rollback from `timekeeping`, the
# re-cutover from `monolith`. Each handoff's transfer waits for a relay to
# drain into timesheet_entries (§10.5 step 3), and HANDOFFS names the
# service that runs it: timekeeping-relay for the first cutover (the
# snapshots its load wrote) and the rollback (Timekeeping's outbox), miru-jobs
# for the re-cutover (the prepared application's local relay). With that
# service stopped, a run that reaches its transfer stays there, which is
# where both interruptions happen: once as a crash, once as a step that
# fails. bin/timekeeping-demo interrupted-handoff drives it in seven steps,
# all under one run name (RUN):
#
#   plan          prints the handoff task to run and the relay service its
#                 transfer waits on, as "<task> <service>"
#   held          (relay running) on each seeded business, the employee
#                 creates entry X and edits it, and the admin saves a draft
#                 with a direct line for X; the candidates leave X out, and
#                 the draft's commit is delivered (no ledger under `legacy`)
#   paused        (the script has stopped the relay) the employee creates
#                 entry Y and edits it. Under `timekeeping` and `monolith`
#                 the projection must not hold Y, so the outbox holds it
#                 undelivered and the transfer will have a drain to wait for.
#                 Each entry's record on the owner (version, note, duration,
#                 `locked`, updated_at) is kept
#   transferring  (the script started the handoff task in the background,
#                 with its drain timeout raised) waits until the run stands in
#                 its transfer: both copies frozen at the next generation
#                 under the outgoing owner, and the relay's outbox not drained.
#                 For the first cutover that outbox is Timekeeping's, which
#                 only the load writes, and the journal must hold the
#                 checkpoint the load carried, so the load has run. The script
#                 then kills the run with SIGKILL
#   crashed       (the run killed) both copies are still frozen under the
#                 outgoing owner at the generation the run raised. The journal
#                 holds the financial snapshot the run's close took, which is
#                 kept, and for the first cutover the checkpoint, whose digest
#                 is kept. X and Y on the owner are exactly as `paused` kept
#                 them. The employee's create of an entry and edit of Y, and
#                 the admin's save of a draft holding Y, each answer 503
#                 ownership-moving and change no row here
#   timed_out     (the script ran the handoff task again with a short drain
#                 timeout, the relay still stopped, and it stopped for a
#                 resume: the drain did not finish) the same checks, and the
#                 journal still holds the snapshot and checkpoint `crashed`
#                 kept: a resumed run reuses them and takes neither again
#   resumed       (the script started the relay again and ran the handoff
#                 task to its end) both copies hand the entries to the
#                 incoming owner with admission open at the generation the
#                 first run raised, raised once only; the journal is cleared;
#                 the financial snapshot is identical to the one kept at
#                 `crashed` (§13 item 2); X and Y read back on the incoming
#                 owner as last written, the projection catches up to them,
#                 and the candidates leave X out, as the draft still holds it,
#                 and offer Y (§13 item 3). Then new writes are accepted
#                 again: the employee edits Y, the admin deletes the draft,
#                 which releases X (F2), and the employee discards X and Y
#
# What each step needs from the one before sits in the run's directory under
# tmp/timekeeping (the miru_handoff_journals volume, which every process of
# the existing application shares): `state.json`, and `runner.pid`, which the
# script writes for the kill. Any check that does not hold raises Failed. A
# step that fails leaves the handoff where it stands, for its task to resume
# or abort. A run that finishes leaves, per business, two discarded entries
# and one discarded draft, with nothing reserved, and the handoff done, so
# the demo has moved to the next owner.
class Timekeeping::InterruptedHandoffCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  # The handoff each outgoing owner hands over with, the journal its task
  # keeps, the owner it hands over to, and the service that runs the relay
  # its transfer waits on.
  Handoff = Data.define(:task, :journal, :incoming, :relay)

  HANDOFFS = {
    "legacy" => Handoff.new(
      task: "timekeeping:first_cutover", journal: Timekeeping::FirstCutoverJournal, incoming: "timekeeping", relay: "timekeeping-relay"
    ),
    "timekeeping" => Handoff.new(
      task: "timekeeping:rollback", journal: Timekeeping::RollbackJournal, incoming: "monolith", relay: "timekeeping-relay"
    ),
    "monolith" => Handoff.new(
      task: "timekeeping:recutover", journal: Timekeeping::RecutoverJournal, incoming: "timekeeping", relay: "miru-jobs"
    )
  }.freeze

  DIRECTORY = "tmp/timekeeping/interrupted-handoff"

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # What a refused write must leave unchanged here: the projection, the
  # prepared application's entries, the invoices and their lines, and the
  # invoice operation ledger.
  WRITTEN = [TimesheetEntry, Timekeeping::Entry, Invoice, InvoiceLineItem, Timekeeping::InvoiceOperation].freeze

  # What a run may change: wait is how long, in seconds, a step waits on
  # another process; tenants default to the seeded businesses; directory is
  # where the runs keep their state, and journals the path of a handoff's
  # journal by outgoing owner, where it is not the task's default;
  # handoff_client reads Timekeeping's copy and outbox (a
  # Timekeeping::HandoffClient, built when a step first needs one, by default).
  Options = Data.define(:wait, :tenants, :directory, :journals, :handoff_client) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS, directory: DIRECTORY, journals: {}, handoff_client: nil) = super
  end

  # run: names the writes of one run, the same for every step.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # "<task> <relay service>" for the current owner's handoff.
  def plan
    handoff = HANDOFFS.fetch(ensure_open!.owner)
    "#{handoff.task} #{handoff.relay}"
  end

  # With the relay running, before the handoff.
  def held
    ownership = ensure_open!
    directory.mkpath
    tenants = @options.tenants.map { |tenant| check_held(prepare_tenant(tenant), ownership) }
    write_state("owner" => ownership.owner, "generation" => ownership.generation, "tenants" => tenants)
    say "entry X was written and reserved by a draft on #{tenants.size} businesses, under #{ownership.summary}"
  end

  # With the relay stopped, before the handoff.
  def paused
    state = read_state
    ownership = ensure_open!
    expect_admitted_under!(state, ownership)
    state["tenants"] = state["tenants"].map { |row| check_paused(tenant_for(row), row, state) }
    write_state(state)
    say "with #{handoff_of(state).relay} stopped, entry Y was written on #{state['tenants'].size} businesses, under #{ownership.summary}"
  end

  # With the handoff running in another process, until it stands in its
  # transfer, waiting for the stopped relay.
  def transferring
    state = read_state
    seen = eventually("the handoff stands in its transfer, waiting for #{handoff_of(state).relay} to drain") do
      in_transfer(state)
    end
    say "the handoff stands in its transfer: both copies #{frozen(state)}, #{seen} snapshots undelivered" \
        "#{', the checkpoint loaded' if state['owner'] == 'legacy'}; kill it now"
  end

  # Once the handoff's process was killed in its transfer.
  def crashed
    state = read_state
    expect_both_frozen!(state)
    state["journal"] = journal_digest(state)
    state["financial_snapshot"] = journal_snapshot(state)
    write_state(state)
    check_interrupted(state, "killed in its transfer")
  end

  # Once the handoff, run again, stopped in its transfer for a resume.
  def timed_out
    state = read_state
    expect_both_frozen!(state)
    expect_journal_kept!(state)
    check_interrupted(state, "stopped in its transfer for a resume")
  end

  # Once the handoff has been resumed to its end.
  def resumed
    state = read_state
    ownership = expect_handed_over!(state)
    expect_journal_cleared!(state)
    expect_money_unchanged!(state)
    state["tenants"].each { |row| check_resumed(tenant_for(row), row) }
    say "the handoff resumed to its end (#{ownership.summary}) with money unchanged, every entry and reservation kept, " \
        "and writes accepted again, on #{state['tenants'].size} businesses"
  end

  private

    def log_prefix = "interrupted handoff"

    def wait = @options.wait

    def ensure_open!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.state_open?

      fail! "the interrupted-handoff proof starts with admission open, under any owner; ownership is #{ownership.summary} " \
            "(finish or abort the handoff in progress first)"
    end

    # What reads Timekeeping's copy and outbox, as the handoff tool does.
    def handoff_client = @handoff_client ||= @options.handoff_client || Timekeeping::HandoffClient.new

    def handoff_of(state) = HANDOFFS.fetch(state["owner"])

    def raised(state) = state["generation"] + 1

    def directory = Rails.root.join(@options.directory, @run)

    def note(name) = "Interrupted handoff #{@run} #{name}"

    def number(tenant) = "IHO-#{tenant[:company].id}-#{@run}"

    def created_x = Entry.new(duration: 30.0, note: note("X"))

    def last_x = Entry.new(duration: 35.0, note: note("X, edited"))

    def created_y = Entry.new(duration: 40.0, note: note("Y"))

    def last_y = Entry.new(duration: 45.0, note: note("Y, edited"))

    def refused_y = Entry.new(duration: 50.0, note: note("Y, refused"))

    def after_y = Entry.new(duration: 55.0, note: note("Y, after the handoff"))

    # --- held and paused: the writes before the handoff --------------------

    def check_held(tenant, ownership)
      x = update_entry(tenant, create_entry(tenant, created_x), last_x)
      id = x.id
      rate = candidates(tenant)[id]&.fetch("rate") || fail!("#{tenant[:name]}: the candidates do not offer entry #{id}")
      draft_id = save_draft(tenant, x, rate)
      eventually("the candidates leave out entry #{id}, reserved by draft #{draft_id}") { !candidates(tenant).key?(id) }
      expect_delivered!(draft_id) unless ownership.owner_legacy?
      say "#{tenant[:name]}: entry X #{id} written and reserved by draft #{draft_id}"
      { "company_id" => tenant[:company].id, "x" => id, "draft_id" => draft_id, "rate" => rate }
    end

    # The ledger records a delivery only once the owner answered it, so the
    # owner then holds the reservation committed.
    def expect_delivered!(draft_id)
      eventually("the commit of draft #{draft_id} is delivered") do
        operations = Timekeeping::InvoiceOperation.where(invoice_id: draft_id).to_a
        operations.any? && operations.all? { |operation| operation.state_succeeded? && operation.delivered_at.present? }
      end
    end

    def check_paused(tenant, row, state)
      id = update_entry(tenant, create_entry(tenant, created_y), last_y).id
      if state["owner"] != "legacy" && TimesheetEntry.unscoped.exists?(id)
        fail! "#{tenant[:name]}: the projection already holds entry #{id}, so #{handoff_of(state).relay} is not stopped " \
              "(bin/timekeeping-demo interrupted-handoff stops it)"
      end
      owned = { "x" => owner_facts(tenant, row["x"]), "y" => owner_facts(tenant, id) }
      say "#{tenant[:name]}: entry Y #{id} written, at version #{owned['y']['version']} on the owner"
      row.merge("y" => id, "owned" => owned)
    end

    # --- crashed and timed_out: the handoff interrupted --------------------

    def expect_admitted_under!(state, ownership)
      return if ownership.owner == state["owner"] && ownership.generation == state["generation"]

      fail! "the paused step runs under the owner and generation the held step wrote under (#{state['owner']}, " \
            "generation #{state['generation']}); ownership is #{ownership.summary}"
    end

    def check_interrupted(state, how)
      state["tenants"].each do |row|
        tenant = tenant_for(row)
        expect_unchanged_on_owner!(tenant, row)
        check_fenced(tenant, row)
      end
      say "the handoff #{how} left both copies #{frozen(state)}, its journal holding the financial snapshot its close " \
          "took (#{rows_in(state['financial_snapshot'])} rows)#{' and its checkpoint' if state['owner'] == 'legacy'}, " \
          "and every entry as written; entry and invoice writes were refused, on #{state['tenants'].size} businesses"
    end

    def journal(state)
      kind = handoff_of(state).journal
      kind.new(path: @options.journals.fetch(state["owner"], kind::DEFAULT_PATH))
    end

    def journal_snapshot(state)
      journal = journal(state)
      journal.resume.financial_snapshot || fail!("the handoff's journal #{journal.path} holds no financial snapshot")
    end

    # A digest of what the journal holds: the financial snapshot and, for the
    # first cutover, the one checkpoint its load carried (§10.5 step 4),
    # which must be there at the raised generation.
    def journal_digest(state)
      journal = journal(state)
      resume = journal.resume
      if state["owner"] == "legacy" && resume.checkpoint&.generation != raised(state)
        fail! "the first cutover's journal #{journal.path} holds no checkpoint at generation #{raised(state)}, though its load ran"
      end
      Digest::SHA256.hexdigest(JSON.generate(journal.class.dump(resume)))
    end

    # The journal still holds what the killed run took, so the resumed run
    # compares money against the same snapshot and reconciles the same
    # checkpoint.
    def expect_journal_kept!(state)
      kept = state["journal"] || fail!("nothing kept of the journal for run #{@run}; run the crashed step first")
      return if journal_digest(state) == kept

      differences = Timekeeping::FinancialSnapshot.diff(state["financial_snapshot"], journal_snapshot(state))
      fail! "the handoff's journal no longer holds what the killed run took " \
            "(financial snapshot differences: #{differences.first(5).map(&:to_h)})"
    end

    # The relay's outbox not drained while both copies are frozen at the
    # raised generation: the run is in its transfer, and cannot leave the
    # drain while the relay is stopped. Answers how many snapshots wait.
    def in_transfer(state)
      local, status = Timekeeping::Ownership.current, handoff_client.status
      return unless [local, status.copy].all? { |copy| frozen_at?(copy, state) }
      return if state["owner"] == "legacy" && journal(state).resume.checkpoint.nil?

      undelivered = state["owner"] == "monolith" ? Timekeeping::OutboxSnapshot.undelivered.count : status.outbox.undelivered
      undelivered if undelivered.positive?
    end

    def frozen(state) = "frozen at generation #{raised(state)} under #{state['owner']}"

    def frozen_at?(copy, state)
      copy.owner == state["owner"] && copy.state == "frozen" && copy.generation == raised(state)
    end

    def expect_both_frozen!(state)
      local, remote = Timekeeping::Ownership.current, handoff_client.status.copy
      return if [local, remote].all? { |copy| frozen_at?(copy, state) }

      fail! "expected both copies #{frozen(state)}, as the interrupted handoff leaves them; this one is #{local.summary}, " \
            "Timekeeping's #{TimekeepingReservations::Handoff.summary(remote)}"
    end

    def expect_unchanged_on_owner!(tenant, row)
      %w[x y].each do |name|
        now = owner_facts(tenant, row[name])
        kept = row.dig("owned", name)
        next if now == kept

        fail! "#{tenant[:name]}: entry #{name.upcase} #{row[name]} on the owner moved from #{kept} to #{now} while the handoff " \
              "stood interrupted"
      end
    end

    # The employee's create and edit, and the admin's draft, are each refused
    # as moving and write nothing here.
    def check_fenced(tenant, row)
      y_id = row["y"]
      expect_refused!(tenant, "the employee's create of an entry") do
        as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: refused_y.duration, note: refused_y.note))
      end
      expect_refused!(tenant, "the employee's edit of entry Y #{y_id}") do
        as(tenant, :employee).call(
          :patch, "/api/v1/timesheet_entry/#{y_id}", body: entry_body(tenant, duration: refused_y.duration, note: refused_y.note)
        )
      end
      expect_refused!(tenant, "the admin's save of a draft holding entry Y #{y_id}") do
        as(tenant, :admin).call(:post, "/api/v1/invoices", body: draft_body(tenant, "#{number(tenant)}-REFUSED", y_id, last_y, row["rate"]))
      end
      say "#{tenant[:name]}: an entry create, an edit of entry Y #{y_id} and a draft holding it were each refused with 503 " \
          "ownership-moving, and nothing was written"
    end

    def expect_refused!(tenant, what)
      before = written_rows
      response = yield
      expected = I18n.t("timesheet_entry.ownership_moving")
      unless response.status == 503 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: #{what} answered #{response.status} #{response.body.to_s.truncate(500)}, not 503 #{expected.inspect}"
      end
      fail! "#{tenant[:name]}: #{what} was refused, but changed a row here" unless written_rows == before
    end

    def written_rows
      WRITTEN.to_h { |model| [model.name, model.unscoped.order(:id).map(&:attributes)] }
    end

    # --- resumed: the handoff done ----------------------------------------

    def expect_handed_over!(state)
      incoming = handoff_of(state).incoming
      local, remote = Timekeeping::Ownership.current, handoff_client.status.copy
      handed_over = [local, remote].all? do |copy|
        copy.owner == incoming && copy.state == "open" && copy.generation == raised(state)
      end
      return local if handed_over

      fail! "the resumed step runs once the handoff has finished, #{incoming} owning the entries with admission open at " \
            "generation #{raised(state)} on both copies; this one is #{local.summary}, Timekeeping's " \
            "#{TimekeepingReservations::Handoff.summary(remote)}"
    end

    def expect_journal_cleared!(state)
      path = journal(state).path
      fail! "the handoff finished, but its journal #{path} is still there" if path.exist?
    end

    def expect_money_unchanged!(state)
      kept = state["financial_snapshot"] || fail!("no financial snapshot kept for run #{@run}; run the crashed step first")
      differences = Timekeeping::FinancialSnapshot.diff(kept, Timekeeping::FinancialSnapshot.process)
      fail! "the interrupted handoff changed money: #{differences.first(10).map(&:to_h)}" if differences.any?

      say "the financial snapshot is identical to the one the handoff's close took (#{rows_in(kept)} rows)"
    end

    def check_resumed(tenant, row)
      expect_carried_over!(tenant, row)
      write_again!(tenant, row)
    end

    # Every write accepted before the handoff, and the draft's reservation,
    # on the incoming owner (§13 item 3).
    def expect_carried_over!(tenant, row)
      x_id, y_id, draft_id = row.values_at("x", "y", "draft_id")
      expect_as_written!(tenant, x_id, last_x)
      expect_as_written!(tenant, y_id, last_y)
      eventually("the projection holds entries #{x_id} and #{y_id} as last written") do
        [[x_id, last_x], [y_id, last_y]].all? { |id, entry| projected?(id, entry) }
      end
      offered = candidates(tenant)
      fail! "#{tenant[:name]}: the candidates offer entry X #{x_id}, which draft #{draft_id} holds" if offered.key?(x_id)
      fail! "#{tenant[:name]}: the candidates do not offer entry Y #{y_id}" unless offered.key?(y_id)
      say "#{tenant[:name]}: entries X #{x_id} and Y #{y_id} read back on the incoming owner and in the projection as last " \
          "written, X still reserved by draft #{draft_id}"
    end

    # Writes accepted again once the handoff is done; they also clean up.
    def write_again!(tenant, row)
      x_id, y_id, draft_id = row.values_at("x", "y", "draft_id")
      update_entry(tenant, Entry.new(id: y_id), after_y)
      expect_as_written!(tenant, y_id, after_y)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("the candidates offer entry X #{x_id} again") { candidates(tenant).key?(x_id) }
      [x_id, y_id].each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{x_id} and #{y_id} leave the entry list") { (entry_list(tenant).keys & [x_id, y_id]).empty? }
      say "#{tenant[:name]}: entry Y #{y_id} edited again, draft #{draft_id} deleted, which released X, and both entries discarded"
    end

    def expect_as_written!(tenant, id, entry)
      facts = owner_facts(tenant, id)
      return if facts["note"] == entry.note && facts["duration"] == entry.duration.to_d.round(5).to_s

      fail! "#{tenant[:name]}: entry #{id} reads #{facts.slice('note', 'duration')} on the owner, not as last written " \
            "(#{entry.note.inspect}, #{entry.duration})"
    end

    def projected?(id, entry)
      row = TimesheetEntry.unscoped.find_by(id:)
      row.present? && row.note == entry.note && row.duration.to_d.round(5) == entry.duration.to_d.round(5)
    end

    # --- reads and writes --------------------------------------------------

    # The entry as the current owner holds it (Timekeeping::EntryReads): the
    # legacy table, the remote Timekeeping, or the prepared application's own
    # table, each with the `locked` its reservations derive (§7.1).
    def owner_facts(tenant, id)
      admin = User.find_by!(email: tenant[:admin])
      read = Timekeeping::EntryReads::Find.new(id:, company: tenant[:company], writer: "web")
      record = Current.set(user: admin, company: tenant[:company]) { Timekeeping::EntryReads.call(read) }
      {
        "version" => record.version, "note" => record.note, "duration" => record.duration.to_d.round(5).to_s,
        "locked" => record.locked, "updated_at" => record.updated_at&.utc&.iso8601(6)
      }
    end

    def create_entry(tenant, entry)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: entry.duration, note: entry.note))
      expect_ok!(response, "create an entry for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration: entry.duration, note: entry.note)
    end

    def update_entry(tenant, entry, edited)
      body = entry_body(tenant, duration: edited.duration, note: edited.note)
      expect_ok!(as(tenant, :employee).call(:patch, "/api/v1/timesheet_entry/#{entry.id}", body:), "edit entry #{entry.id}")
      Entry.new(id: entry.id, duration: edited.duration, note: edited.note)
    end

    def save_draft(tenant, entry, rate)
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body: draft_body(tenant, number(tenant), entry.id, entry, rate))
      expect_ok!(response, "save the draft #{number(tenant)}")
      response.json.fetch("id")
    end

    def draft_body(tenant, number, entry_id, entry, rate)
      {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601, currency: tenant[:company].base_currency,
          invoice_line_items_attributes: [
            { name: "Interrupted handoff", date: Date.current.iso8601, timesheet_entry_id: entry_id, quantity: entry.duration, rate: }
          ]
        }
      }
    end

    # --- the run's state ---------------------------------------------------

    def rows_in(snapshot) = snapshot.sum { |_table, rows| rows.size }

    def write_state(state)
      directory.join("state.json").write(JSON.generate(state))
    end

    def read_state
      path = directory.join("state.json")
      fail! "no held step for run #{@run} (#{path}); run the held step first" unless path.exist?

      JSON.parse(path.read)
    end

    def tenant_for(row)
      tenant = @options.tenants.map { |candidate| prepare_tenant(candidate) }.find { |candidate| candidate[:company].id == row["company_id"] }
      tenant || fail!("the run #{@run} wrote on company #{row['company_id']}, which is none of the businesses checked")
    end
end
