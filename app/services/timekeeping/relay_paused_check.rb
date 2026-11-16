# frozen_string_literal: true

# The relay-paused proof of docs/architecture/timekeeping-soa.md §13 item 5
# (§12.4 "relay paused"), against the two running applications of the local
# demo (§11.2):
#
#   Relay paused: a newly created entry can be invoiced at once and appears
#   in the entry list. The projection catches up when the relay resumes.
#
# It runs while Timekeeping owns the entries with admission open, in two
# halves around a stopped relay. bin/timekeeping-demo relay-paused stops
# timekeeping-relay, runs #paused, starts the relay again and runs #resumed.
# Both halves name their writes after the same run, so the second finds what
# the first wrote. On each seeded business, over the public API as its users
# (Timekeeping::PublicApi):
#
#   paused   the employee creates an entry, and the employee's entry list
#            shows it at once; the projection (timesheet_entries) holds no
#            row for it, so the relay has not delivered it; the admin's
#            invoice candidates offer it at once, the admin saves a draft
#            with a direct line for it, and the candidates then leave it out
#            (prepare from miru-web, commit from the invoice operation
#            worker in miru-jobs); and the time-entries report, which reads
#            the projection, still does not show it
#   resumed  the time-entries report shows the entry as written (the
#            projection caught up); the candidates still leave it out, as
#            the draft still holds it; then the admin deletes the draft (a
#            discard, which releases it, F2), the employee discards the
#            entry, and both leave the candidates, the entry list and the
#            report
#
# If the projection already holds the entry while the relay should be
# stopped, the run fails: it would prove nothing. Any check that does not
# hold raises Failed. A run that finishes leaves, per business, one discarded
# entry and one discarded draft, and nothing reserved; one that fails leaves
# what it wrote for inspection.
class Timekeeping::RelayPausedCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  DURATION = 45.0

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # run: names the writes of one run, the same for both halves.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # While Timekeeping's relay is stopped.
  def paused
    ownership = ensure_timekeeping_owns!
    @options.tenants.each { |tenant| check_paused(prepare_tenant(tenant)) }
    say "with the relay paused, a new entry was listed and invoiced at once on #{@options.tenants.size} businesses, " \
        "at generation #{ownership.generation}"
  end

  # Once Timekeeping's relay runs again.
  def resumed
    ownership = ensure_timekeeping_owns!
    @options.tenants.each { |tenant| check_resumed(prepare_tenant(tenant)) }
    say "once the relay resumed, the projection caught up on #{@options.tenants.size} businesses, " \
        "at generation #{ownership.generation}"
  end

  private

    def log_prefix = "relay paused"

    def wait = @options.wait

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the relay-paused proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note = "Relay paused #{@run}"

    def number(tenant) = "RLP-#{tenant[:company].id}-#{@run}"

    def check_paused(tenant)
      entry = create_entry(tenant)
      id = entry.id
      fail! "#{tenant[:name]}: entry #{id} is not in the entry list at once" unless same?(entry, entry_list(tenant)[id])
      ensure_unprojected!(tenant, id)
      rate = candidates(tenant)[id]&.fetch("rate") || fail!("#{tenant[:name]}: the candidates do not offer entry #{id} at once")
      draft_id = save_draft(tenant, entry, rate)
      eventually("the candidates leave out entry #{id}, reserved by draft #{draft_id}") { !candidates(tenant).key?(id) }
      ensure_unprojected!(tenant, id)
      if time_entries_report(tenant).key?(id)
        fail! "#{tenant[:name]}: the time-entries report shows entry #{id} while the relay is paused"
      end

      say "#{tenant[:name]}: entry #{id}, not yet projected, was listed at once and reserved by draft #{draft_id}"
    end

    def check_resumed(tenant)
      entry = find_entry(tenant)
      id = entry.id
      draft_id = Invoice.kept.where(company: tenant[:company], invoice_number: number(tenant)).pick(:id) ||
        fail!("#{tenant[:name]}: no kept draft #{number(tenant)}; run the paused half first")
      eventually("the time-entries report shows entry #{id} as written") { same?(entry, time_entries_report(tenant)[id]) }
      fail! "#{tenant[:name]}: the candidates offer entry #{id}, which draft #{draft_id} holds" if candidates(tenant).key?(id)
      say "#{tenant[:name]}: the projection caught up with entry #{id}, still reserved by draft #{draft_id}"

      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("the candidates offer entry #{id} again") { candidates(tenant).key?(id) }
      delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}")
      eventually("entry #{id} leaves the entry list and the time-entries report") do
        !entry_list(tenant).key?(id) && !time_entries_report(tenant).key?(id)
      end
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entry #{id}"
    end

    # The projection is this application's timesheet_entries: the relay's
    # one destination (§3.2). A row there means the relay is not paused.
    def ensure_unprojected!(tenant, id)
      return unless TimesheetEntry.unscoped.exists?(id)

      fail! "#{tenant[:name]}: the projection already holds entry #{id}, so the relay is not paused " \
            "(stop timekeeping-relay first; bin/timekeeping-demo relay-paused does)"
    end

    def create_entry(tenant)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: DURATION, note:))
      expect_ok!(response, "create an entry for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration: DURATION, note:)
    end

    # The one entry the paused half wrote, as the owner lists it.
    def find_entry(tenant)
      rows = entry_list(tenant).values.select { |row| row["note"] == note }
      fail! "#{tenant[:name]}: the entry list holds #{rows.size} entries noted #{note.inspect}, not one" unless rows.one?

      Entry.new(id: rows.first["id"], duration: DURATION, note:)
    end

    def save_draft(tenant, entry, rate)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number(tenant), status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency,
          invoice_line_items_attributes: [
            { name: "Relay paused", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
          ]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number(tenant)}")
      response.json.fetch("id")
    end
end
