# frozen_string_literal: true

# The "projection consumer down" row of docs/architecture/timekeeping-soa.md
# §9.3, part of §12.4's failure injection, against the two running
# applications of the local demo (§11.2):
#
#   | Projection consumer down | Same as relay paused | Relay retries; upsert by version |
#
# "Same as relay paused" is the row above it: the projection lags, so
# `locked` and the aggregates read from it are stale, while candidate
# selection and the entry list read Timekeeping (§3.3), so invoicing a new
# entry works at once.
#
# It runs while Timekeeping owns the entries with admission open, in three
# steps. bin/timekeeping-demo consumer-down runs #projected, then takes the
# consumer down as timekeeping-relay meets it while the relay keeps running,
# runs #down, finds the relay's refused deliveries in its log, brings the
# consumer back without restarting anything, and runs #restored. All three
# name their writes after the same run, so each finds what the one before it
# wrote. On each seeded business, over the public API as its users
# (Timekeeping::PublicApi):
#
#   projected  the employee creates entry X, and the projection
#              (timesheet_entries) holds it as Timekeeping does: the
#              consumer is up
#   down       the employee edits X and creates entry Y, and the entry list
#              shows both as written at once; the projection still holds X
#              as it was before the edit, and no Y; the invoice candidates
#              offer both at once, the admin saves a draft with a direct
#              line for each, and the candidates then leave both out, while
#              Timekeeping now holds X at a later version; then, after
#              `settle` seconds more of the relay's retries, the projection
#              is still as it was, and the time-entries report, which reads
#              it, still shows X as it was before the edit and no Y
#   restored   the projection holds X and Y as Timekeeping does, at the
#              version Timekeeping holds with the edit and the draft's
#              reservation in it, though the outbox held older snapshots of
#              both (the relay's resend, upserted by version); the report
#              shows both as written, and the candidates still leave both
#              out; then the admin deletes the draft (a discard, which
#              releases them, F2), the employee discards X and Y, and the
#              projection holds both discarded
#
# A projection that moves while the consumer should be down fails the run: it
# would prove nothing. Any check that does not hold raises Failed. A run that
# finishes leaves, per business, two discarded entries and one discarded
# draft, and nothing reserved; one that fails leaves what it wrote for
# inspection.
class Timekeeping::ConsumerDownCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # What the projection and Timekeeping are compared on: what the edit, the
  # reservation and the discard change.
  FACTS = %w[version note duration locked bill_status].freeze

  CREATED = 30.0
  EDITED = 50.0
  NEW = 45.0

  # How long, in seconds, the down step keeps watching the projection after
  # its last write: Timekeeping's relay runs every second
  # (services/timekeeping/config/solid_queue.yml), so this spans several of
  # its refused deliveries.
  DEFAULT_SETTLE = 5

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; settle is the down step's watch; tenants default to the seeded
  # businesses.
  Options = Data.define(:wait, :settle, :tenants) do
    def initialize(wait: DEFAULT_WAIT, settle: DEFAULT_SETTLE, tenants: TENANTS) = super
  end

  # run: names the writes of one run, the same for all three steps.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # While the consumer is up, before it is taken down.
  def projected
    each_tenant { |tenant| check_projected(tenant) }
    say "entry X is projected as Timekeeping holds it on #{@options.tenants.size} businesses; the consumer is up"
  end

  # While the consumer is down and Timekeeping's relay keeps running.
  def down
    ownership = each_tenant { |tenant| check_down(tenant) }
    say "with the projection consumer down, an edited and a new entry were listed and invoiced at once on " \
        "#{@options.tenants.size} businesses, and the projection stayed as it was, at generation #{ownership.generation}"
  end

  # Once the consumer is back, the relay unchanged.
  def restored
    ownership = each_tenant { |tenant| check_restored(tenant) }
    say "once the consumer was back, the relay's resend brought the projection to Timekeeping's versions on " \
        "#{@options.tenants.size} businesses, at generation #{ownership.generation}"
  end

  private

    def log_prefix = "consumer down"

    def wait = @options.wait

    def each_tenant
      ownership = ensure_timekeeping_owns!
      @options.tenants.each { |tenant| yield prepare_tenant(tenant) }
      ownership
    end

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the consumer-down proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(name) = "Consumer down #{@run} #{name}"

    def number(tenant) = "CND-#{tenant[:company].id}-#{@run}"

    def created_x = Entry.new(duration: CREATED, note: note("X"))

    def edited_x = Entry.new(duration: EDITED, note: note("X, edited"))

    def new_y = Entry.new(duration: NEW, note: note("Y"))

    def check_projected(tenant)
      x = create_entry(tenant, created_x)
      facts = eventually("the projection holds entry #{x.id} as Timekeeping does") { projected_as_owned(tenant, x.id) }
      say "#{tenant[:name]}: entry X #{x.id} is projected at version #{facts['version']}"
    end

    def check_down(tenant)
      created = find_entry(tenant, created_x)
      id = created.id
      before = projected_as_owned(tenant, id) ||
        refuse!(tenant, "the projection does not hold entry #{id} as Timekeeping does; run the projected step first, with the consumer up")
      edited, added = write_while_down(tenant, created, before)
      draft_id = invoice_at_once(tenant, [edited, added])
      version = owned_facts(tenant, id).fetch("version")
      refuse!(tenant, "Timekeeping holds entry #{id} at version #{version}, not after #{before['version']}") if version <= before["version"]

      sleep @options.settle
      ensure_still_stale!(tenant, edited, added, before)
      say "#{tenant[:name]}: entry X #{id}, edited, and new entry Y #{added.id} were listed at once and reserved by draft #{draft_id}; " \
          "Timekeeping holds X at version #{version}, the projection still at #{before['version']}, and no Y"
    end

    # The edit of X and the create of Y, each listed at once and not
    # projected. Answers both as written.
    def write_while_down(tenant, created, before)
      edited = update_entry(tenant, created, edited_x)
      ensure_listed!(tenant, edited, "as edited at once")
      ensure_stale!(tenant, edited.id, before)
      added = create_entry(tenant, new_y)
      ensure_listed!(tenant, added, "at once")
      ensure_unprojected!(tenant, added.id)
      [edited, added]
    end

    # The candidates offer the entries at once, and a draft with a direct line
    # for each reserves them. Answers the draft's id.
    def invoice_at_once(tenant, entries)
      offered = candidates(tenant)
      lines = entries.map do |entry|
        id = entry.id
        [entry, offered[id]&.fetch("rate") || refuse!(tenant, "the candidates do not offer entry #{id} at once")]
      end
      draft_id = save_draft(tenant, lines)
      ids = entries.map(&:id)
      eventually("the candidates leave out entries #{ids}, reserved by draft #{draft_id}") do
        offered = candidates(tenant)
        ids.none? { |id| offered.key?(id) }
      end
      draft_id
    end

    def ensure_still_stale!(tenant, edited, added, before)
      x_id, y_id = edited.id, added.id
      ensure_stale!(tenant, x_id, before)
      ensure_unprojected!(tenant, y_id)
      report = time_entries_report(tenant)
      unless same?(created_x, report[x_id])
        refuse!(tenant, "the time-entries report does not show entry #{x_id} as it was before the edit, so the projection is not stale")
      end
      refuse!(tenant, "the time-entries report shows entry #{y_id} while the consumer is down") if report.key?(y_id)
    end

    def check_restored(tenant)
      entries = [find_entry(tenant, edited_x), find_entry(tenant, new_y)]
      number = number(tenant)
      draft_id = Invoice.kept.where(company: tenant[:company], invoice_number: number).pick(:id) ||
        refuse!(tenant, "no kept draft #{number}; run the down step first")

      versions = entries.map do |entry|
        id = entry.id
        eventually("the projection holds entry #{id} as Timekeeping does") { projected_as_owned(tenant, id) }.fetch("version")
      end
      ensure_caught_up!(tenant, entries, draft_id)
      x_id, y_id = entries.map(&:id)
      say "#{tenant[:name]}: the projection caught up with entry X #{x_id} at version #{versions.first} and entry Y #{y_id} " \
          "at version #{versions.last}, still reserved by draft #{draft_id}"

      clean_up(tenant, draft_id, entries)
    end

    # The report, which reads the projection, shows each entry as written,
    # and the candidates still leave them out.
    def ensure_caught_up!(tenant, entries, draft_id)
      report, offered = time_entries_report(tenant), candidates(tenant)
      entries.each do |entry|
        id = entry.id
        refuse!(tenant, "the time-entries report does not show entry #{id} as written") unless same?(entry, report[id])
        refuse!(tenant, "the candidates offer entry #{id}, which draft #{draft_id} holds") if offered.key?(id)
      end
    end

    def clean_up(tenant, draft_id, entries)
      ids = entries.map(&:id)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("the candidates offer entries #{ids} again") { ids.all? { |id| candidates(tenant).key?(id) } }
      ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{ids} leave the entry list and the time-entries report") do
        listed, reported = entry_list(tenant), time_entries_report(tenant)
        ids.none? { |id| listed.key?(id) || reported.key?(id) }
      end
      ids.each { |id| eventually("the projection holds entry #{id} discarded") { projected_facts(id)&.fetch("discarded") } }
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entries #{ids.join(' and ')}"
    end

    # The projection is this application's timesheet_entries: the relay's
    # one destination (§3.2). Any change there means the consumer is not
    # down.
    def ensure_stale!(tenant, id, before)
      now = projected_facts(id)
      return if now == before

      fail! "#{tenant[:name]}: the projection moved entry #{id} from #{before} to #{now}, so the consumer is not down " \
            "(bin/timekeeping-demo consumer-down takes it down)"
    end

    def ensure_listed!(tenant, entry, how)
      id = entry.id
      refuse!(tenant, "the entry list does not show entry #{id} #{how}") unless same?(entry, entry_list(tenant)[id])
    end

    def refuse!(tenant, message) = fail!("#{tenant[:name]}: #{message}")

    def ensure_unprojected!(tenant, id)
      return unless TimesheetEntry.unscoped.exists?(id)

      fail! "#{tenant[:name]}: the projection already holds entry #{id}, so the consumer is not down " \
            "(bin/timekeeping-demo consumer-down takes it down)"
    end

    # The projected row's facts when they are Timekeeping's, else nil.
    def projected_as_owned(tenant, id)
      facts = projected_facts(id)
      facts if facts && facts == owned_facts(tenant, id)
    end

    def projected_facts(id)
      row = TimesheetEntry.unscoped.find_by(id:)
      row && facts(row.attributes)
    end

    # Timekeeping's own record of the entry (§5.2 show), kept entries only.
    def owned_facts(tenant, id)
      claims = Timekeeping::UserToken.system_claims(company: tenant[:company], writer: "invoice", request_id: SecureRandom.uuid)
      facts(Timekeeping::EntryClient.new.show_entry(id, claims:))
    end

    def facts(attributes)
      attributes.slice(*FACTS).merge(
        "duration" => attributes["duration"].to_d.round(5), "discarded" => attributes["discarded_at"].present?
      )
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

    # The one entry an earlier step wrote with entry's note, as the owner
    # lists it.
    def find_entry(tenant, entry)
      rows = entry_list(tenant).values.select { |row| row["note"] == entry.note }
      fail! "#{tenant[:name]}: the entry list holds #{rows.size} entries noted #{entry.note.inspect}, not one" unless rows.one?

      Entry.new(id: rows.first["id"], duration: entry.duration, note: entry.note)
    end

    def save_draft(tenant, lines)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number(tenant), status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency,
          invoice_line_items_attributes: lines.map do |entry, rate|
            { name: "Consumer down", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
          end
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number(tenant)}")
      response.json.fetch("id")
    end
end
