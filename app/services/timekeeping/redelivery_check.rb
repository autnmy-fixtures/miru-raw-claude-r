# frozen_string_literal: true

# The "duplicate and reordered delivery" of docs/architecture/timekeeping-soa.md
# §13 item 6, against the two running applications of the local demo
# (§11.2). The projection consumer upserts each entry snapshot by
# (entry_id, version) and ignores anything not newer (§5.4, §9.3 "Relay
# retries; upsert by version"), so a snapshot that arrives twice, or after a
# newer one, must change nothing.
#
# It runs while Timekeeping owns the entries with admission open, in four
# steps. bin/timekeeping-demo redelivery runs #projected with the relay
# running, stops timekeeping-relay, and runs #held, which names the run's
# entries on its last line. Then, in timekeeping-web, Timekeeping resends
# those entries' outbox snapshots through its relay's own call, out of order
# and twice (bin/rails timekeeping:redeliver, OutboxRedelivery there): each
# entry's newest first, which the consumer must apply, then each older one
# alone, then all of them again, which it must ignore. It marks nothing, so
# the outbox still holds them undelivered. The script runs #reordered with
# the relay still stopped, starts the relay, waits until Timekeeping counts
# nothing undelivered, which means the relay has sent every one of those
# snapshots again, and runs #duplicated. All four name their writes after
# the same run. On each seeded business, over the public API as its users
# (Timekeeping::PublicApi):
#
#   projected   the employee creates entry X, and the projection
#               (timesheet_entries) holds it as Timekeeping does
#   held        the employee edits X twice and creates and edits entry Y,
#               and the admin saves a draft with a direct line for each;
#               once its commit is delivered, Timekeeping holds X and Y
#               reserved, at later versions, while the projection still
#               holds X as it was created, and no Y: the relay is stopped.
#               Its last line is "redelivery: entries: <ids>"
#   reordered   with the relay still stopped, the projection holds X (an
#               overwrite) and Y (an insert) exactly as Timekeeping does,
#               though every older snapshot of both reached it after the
#               newest; the time-entries report shows both as last written
#   duplicated  once the relay has delivered all of them again, the
#               projection is still exactly as Timekeeping holds it; then
#               the admin deletes the draft (a discard, which releases them,
#               F2), the employee discards X and Y, and the projection holds
#               both discarded
#
# What is compared is every fact a stale or older snapshot would show:
# version, note, duration, project, work date, `locked`, bill status and
# updated_at. Any check that does not hold raises Failed. A run that
# finishes leaves, per business, two discarded entries and one discarded
# draft, and nothing reserved; one that fails leaves what it wrote for
# inspection.
class Timekeeping::RedeliveryCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  FACTS = %w[version note duration project_id work_date locked bill_status updated_at].freeze

  # The held step's last line, which the demo script reads.
  ENTRIES_LINE = "entries:"

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # run: names the writes of one run, the same for all four steps.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # With the relay running.
  def projected
    each_tenant { |tenant| check_projected(tenant) }
    say "entry X is projected as Timekeeping holds it on #{@options.tenants.size} businesses"
  end

  # With the relay stopped. Answers the run's entry ids, X and Y per business.
  def held
    ids = []
    ownership = each_tenant { |tenant| ids.concat(check_held(tenant)) }
    say "with the relay stopped, entries X and Y were edited and reserved on #{@options.tenants.size} businesses, " \
        "and the projection stayed behind, at generation #{ownership.generation}"
    say "#{ENTRIES_LINE} #{ids.join(' ')}"
    ids
  end

  # With the relay still stopped, after Timekeeping's out-of-order resend.
  def reordered
    ownership = each_tenant { |tenant| check_reordered(tenant) }
    say "with the relay stopped, the out-of-order resend left the projection at Timekeeping's versions on " \
        "#{@options.tenants.size} businesses, at generation #{ownership.generation}"
  end

  # Once the relay has delivered every snapshot again.
  def duplicated
    ownership = each_tenant { |tenant| check_duplicated(tenant) }
    say "the relay's second delivery of every snapshot changed nothing on #{@options.tenants.size} businesses, " \
        "at generation #{ownership.generation}"
  end

  private

    def log_prefix = "redelivery"

    def wait = @options.wait

    def each_tenant
      ownership = ensure_timekeeping_owns!
      @options.tenants.each { |tenant| yield prepare_tenant(tenant) }
      ownership
    end

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the redelivery proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(name) = "Redelivery #{@run} #{name}"

    def number(tenant) = "RDL-#{tenant[:company].id}-#{@run}"

    def created_x = Entry.new(duration: 20.0, note: note("X"))

    def edited_x = Entry.new(duration: 25.0, note: note("X, edited"))

    def last_x = Entry.new(duration: 35.0, note: note("X, edited again"))

    def created_y = Entry.new(duration: 40.0, note: note("Y"))

    def last_y = Entry.new(duration: 55.0, note: note("Y, edited"))

    def check_projected(tenant)
      x = create_entry(tenant, created_x)
      facts = eventually("the projection holds entry #{x.id} as Timekeeping does") { projected_as_owned(tenant, x.id) }
      say "#{tenant[:name]}: entry X #{x.id} is projected at version #{facts['version']}"
    end

    # Answers [X's id, Y's id].
    def check_held(tenant)
      x = find_entry(tenant, created_x)
      before = projected_as_owned(tenant, x.id) ||
        refuse!(tenant, "the projection does not hold entry #{x.id} as Timekeeping does; run the projected step first, with the relay running")
      x = update_entry(tenant, update_entry(tenant, x, edited_x), last_x)
      y = update_entry(tenant, create_entry(tenant, created_y), last_y)
      entries = [x, y]
      draft_id = reserve(tenant, entries)

      ensure_behind!(tenant, x.id, before)
      ensure_unprojected!(tenant, y.id)
      versions = entries.map { |entry| owned_facts(tenant, entry.id).fetch("version") }
      say "#{tenant[:name]}: Timekeeping holds entry X #{x.id} at version #{versions.first} and entry Y #{y.id} at version " \
          "#{versions.last}, both reserved by draft #{draft_id}; the projection holds X at version #{before['version']} and no Y"
      entries.map(&:id)
    end

    # The admin saves a draft with a direct line for each entry, the
    # candidates leave both out, and the draft's commit is delivered: the
    # ledger records a delivery only once Timekeeping answered it, so
    # Timekeeping then holds each entry reserved and changes it no further.
    # Answers the draft's id.
    def reserve(tenant, entries)
      offered = candidates(tenant)
      lines = entries.map do |entry|
        [entry, offered[entry.id]&.fetch("rate") || refuse!(tenant, "the candidates do not offer entry #{entry.id}")]
      end
      draft_id = save_draft(tenant, lines)
      ids = entries.map(&:id)
      eventually("the candidates leave out entries #{ids}, reserved by draft #{draft_id}") do
        offered = candidates(tenant)
        ids.none? { |id| offered.key?(id) }
      end
      eventually("the commit of draft #{draft_id} is delivered") do
        operations = Timekeeping::InvoiceOperation.where(invoice_id: draft_id).to_a
        operations.any? && operations.all? { |operation| operation.state_succeeded? && operation.delivered_at.present? }
      end
      draft_id
    end

    def check_reordered(tenant)
      entries = [find_entry(tenant, last_x), find_entry(tenant, last_y)]
      entries.each do |entry|
        id = entry.id
        projected_as_owned(tenant, id) ||
          refuse!(tenant, "the projection holds entry #{id} as #{projected_facts(id).inspect}, not as Timekeeping does " \
                          "(#{owned_facts(tenant, id)}); run timekeeping:redeliver in timekeeping-web first")
      end
      ensure_reported!(tenant, entries)
      x_id, y_id = entries.map(&:id)
      say "#{tenant[:name]}: with the relay stopped, the projection holds entry X #{x_id} and entry Y #{y_id} as Timekeeping does, " \
          "after every older snapshot of both arrived after the newest"
    end

    def check_duplicated(tenant)
      entries = [find_entry(tenant, last_x), find_entry(tenant, last_y)]
      number = number(tenant)
      draft_id = Invoice.kept.where(company: tenant[:company], invoice_number: number).pick(:id) ||
        refuse!(tenant, "no kept draft #{number}; run the held step first")
      entries.each do |entry|
        id = entry.id
        projected_as_owned(tenant, id) ||
          refuse!(tenant, "after the relay's second delivery the projection holds entry #{id} as #{projected_facts(id).inspect}, " \
                          "not as Timekeeping does (#{owned_facts(tenant, id)})")
      end
      ensure_reported!(tenant, entries)
      offered = candidates(tenant)
      entries.each { |entry| refuse!(tenant, "the candidates offer entry #{entry.id}, which draft #{draft_id} holds") if offered.key?(entry.id) }
      say "#{tenant[:name]}: after the relay delivered them again, the projection still holds entries #{entries.map(&:id).join(' and ')} " \
          "as Timekeeping does, reserved by draft #{draft_id}"

      clean_up(tenant, draft_id, entries)
    end

    # The time-entries report reads the projection.
    def ensure_reported!(tenant, entries)
      report = time_entries_report(tenant)
      entries.each do |entry|
        refuse!(tenant, "the time-entries report does not show entry #{entry.id} as last written") unless same?(entry, report[entry.id])
      end
    end

    def clean_up(tenant, draft_id, entries)
      ids = entries.map(&:id)
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("the candidates offer entries #{ids} again") { ids.all? { |id| candidates(tenant).key?(id) } }
      ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      ids.each { |id| eventually("the projection holds entry #{id} discarded") { projected_discarded?(id) } }
      say "#{tenant[:name]}: deleted draft #{draft_id} and discarded entries #{ids.join(' and ')}"
    end

    # The projection is this application's timesheet_entries, and only the
    # relay writes it. Any change there means the relay is not stopped.
    def ensure_behind!(tenant, id, before)
      now = projected_facts(id)
      return if now == before

      fail! "#{tenant[:name]}: the projection moved entry #{id} from #{before} to #{now}, so the relay is not stopped " \
            "(bin/timekeeping-demo redelivery stops it)"
    end

    def ensure_unprojected!(tenant, id)
      return unless TimesheetEntry.unscoped.exists?(id)

      fail! "#{tenant[:name]}: the projection already holds entry #{id}, so the relay is not stopped " \
            "(bin/timekeeping-demo redelivery stops it)"
    end

    def refuse!(tenant, message) = fail!("#{tenant[:name]}: #{message}")

    # The projected row's facts when they are Timekeeping's, else nil.
    def projected_as_owned(tenant, id)
      facts = projected_facts(id)
      facts if facts && facts == owned_facts(tenant, id)
    end

    def projected_facts(id)
      row = TimesheetEntry.unscoped.find_by(id:)
      row && facts(row.attributes)
    end

    def projected_discarded?(id) = TimesheetEntry.unscoped.where(id:).where.not(discarded_at: nil).exists?

    # Timekeeping's own record of the entry (§5.2 show), kept entries only.
    def owned_facts(tenant, id)
      claims = Timekeeping::UserToken.system_claims(company: tenant[:company], writer: "invoice", request_id: SecureRandom.uuid)
      facts(Timekeeping::EntryClient.new.show_entry(id, claims:))
    end

    # The row's or the contract's values, in one form: the contract carries
    # dates and times as ISO 8601 strings (§5.1).
    def facts(attributes)
      attributes.slice(*FACTS).merge(
        "duration" => attributes["duration"].to_d.round(5),
        "work_date" => attributes["work_date"].to_s,
        "updated_at" => instant(attributes["updated_at"])
      )
    end

    def instant(value) = (value.is_a?(String) ? Time.iso8601(value) : value)&.utc&.iso8601(6)

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
            { name: "Redelivery", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
          end
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number(tenant)}")
      response.json.fetch("id")
    end
end
