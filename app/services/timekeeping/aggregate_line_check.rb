# frozen_string_literal: true

# The aggregate-line proof of docs/architecture/timekeeping-soa.md §12.4 (F3,
# §2.3, D6), against the two running applications of the local demo (§11.2):
#
#   Aggregate line removed from a draft (F3). A draft holds a direct line for
#   entry X and a grouped line that references X and Y. Removing the grouped
#   line keeps X reserved, because the direct line still references it, and
#   releases Y. Removing the remaining direct line releases X. Destroying the
#   draft releases its whole set. A save or destroy that fails keeps every
#   prior reservation.
#
# It runs while Timekeeping owns the entries with admission open, in three
# steps around a stopped timekeeping-web. bin/timekeeping-demo aggregate-line
# runs #held, stops timekeeping-web, runs #outage, starts it again and runs
# #restored. All three name their writes after the same run, so each finds
# what the one before wrote. On each seeded business, over the public API as
# its users (Timekeeping::PublicApi):
#
#   held      the employee creates entries X, Y and W. The admin saves the
#             draft with a direct line for X and a grouped line linking X and
#             Y, and a second draft with a direct line for W. Then four saves
#             of the draft: one that fails, as it adds W, which the second
#             draft holds (F1: 422, and X and Y stay reserved); one that
#             removes the grouped line (X stays reserved, Y is offered again);
#             one that removes the direct line (X is offered again); and one
#             that puts both lines back (X and Y reserved again)
#   outage    with Timekeeping stopped, so the invoice candidates answer 503:
#             a save that removes the grouped line, and a bulk delete (the
#             hard destroy of §1.4), each answer 503, and the draft keeps both
#             lines; the invoice operation ledger records both as failed
#   restored  with Timekeeping started again: the candidates still leave out
#             X, Y and W, as every reservation outlived the two failures, and
#             the ledger delivers both aborts. Then a bulk delete destroys the
#             draft and releases X and Y together, while W stays with the
#             second draft. Last, the admin deletes the second draft and the
#             employee discards the three entries
#
# Reservations are read where the invoice editor reads them: the candidates
# (§3.3), which come from the owner, offer an entry exactly when nothing
# reserves it. The draft's lines are read here, from this application's
# invoice tables. Removals take effect at commit, which the invoice operation
# worker delivers, so a check of what is offered waits for it. If the
# candidates answer while Timekeeping should be stopped, the outage step fails
# before it writes: it would prove nothing. Any check that does not hold raises
# Failed. A run that finishes leaves, per business, three discarded entries,
# one discarded draft and nothing reserved; one that fails leaves what it wrote
# for inspection.
class Timekeeping::AggregateLineCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # The ids of a run's three entries on one business: X, which the direct
  # line references (and the grouped line too), Y, which only the grouped
  # line links, and W, which the second draft holds.
  Ids = Data.define(:direct, :linked, :other) do
    def all = [direct, linked, other]
  end

  # The three entries of a run, by the letters §12.4 names them, and W, the
  # one the second draft holds.
  DURATIONS = { "X" => 30.0, "Y" => 50.0, "W" => 20.0 }.freeze

  BULK_DELETE = "/api/v1/invoices/bulk_deletion"

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
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

  # While Timekeeping runs.
  def held
    each_tenant { |tenant| check_held(tenant) }
    report "removing a draft's grouped line kept the entry its direct line references and released the other"
  end

  # While timekeeping-web is stopped.
  def outage
    each_tenant { |tenant| check_outage(tenant) }
    report "with Timekeeping stopped, a save and a destroy of the draft failed and left both its lines"
  end

  # Once timekeeping-web runs again.
  def restored
    each_tenant { |tenant| check_restored(tenant) }
    report "every reservation outlived the failed save and destroy, and destroying the draft released its whole set"
  end

  private

    def log_prefix = "aggregate line"

    def wait = @options.wait

    def each_tenant
      @ownership = ensure_timekeeping_owns!
      @options.tenants.each { |tenant| yield prepare_tenant(tenant) }
    end

    def report(what)
      say "#{what}, on #{@options.tenants.size} businesses, at generation #{@ownership.generation}"
    end

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the aggregate-line proof runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def note(letter) = "Aggregate line #{@run} #{letter}"

    def number(tenant) = "AGL-#{tenant[:company].id}-#{@run}"

    def other_number(tenant) = "#{number(tenant)}-W"

    # --- the three steps ------------------------------------------------

    def check_held(tenant)
      x, y, w = DURATIONS.map { |letter, duration| create_entry(tenant, letter, duration) }
      ids = Ids.new(direct: x.id, linked: y.id, other: w.id)
      rate = candidate_rate(tenant, ids)
      both_lines = [direct(x, rate), grouped([x, y], rate)]
      other_line = direct(w, rate)

      draft_id = save_drafts(tenant, ids, both_lines, other_line)
      refused_save(tenant, draft_id, ids, other_line)
      removals(tenant, draft_id, ids)
      lines_back(tenant, draft_id, ids, both_lines)
    end

    def check_outage(tenant)
      ensure_timekeeping_down!(tenant)
      draft_id, x_id, y_id = find_draft(tenant)
      grouped_id = grouped_line_id(tenant, draft_id)

      failed = update(tenant, draft_id, [{ id: grouped_id, _destroy: "1" }])
      expect_unavailable!(tenant, failed, "the save removing the grouped line of draft #{draft_id}")
      failed = as(tenant, :admin).call(:post, BULK_DELETE, body: { invoices_ids: [draft_id] })
      expect_unavailable!(tenant, failed, "the bulk delete of draft #{draft_id}")

      expect_lines!(tenant, draft_id, [x_id, y_id])
      expect_failed_intents!(tenant, draft_id)
      say "#{tenant[:name]}: with Timekeeping stopped, the save and the destroy of draft #{draft_id} failed with 503, " \
          "and it keeps both lines, for entries #{x_id} and #{y_id}"
    end

    def check_restored(tenant)
      draft_id, x_id, y_id = find_draft(tenant)
      other_id, w_id = find_other_draft(tenant)
      ids = Ids.new(direct: x_id, linked: y_id, other: w_id)
      ensure_held_through_failures!(tenant, draft_id, ids)

      destroy!(tenant, draft_id)
      expect_reserved_ids!(tenant, held: [w_id], offered: [x_id, y_id], after: "destroying draft #{draft_id}")
      say "#{tenant[:name]}: destroying draft #{draft_id} released entries #{x_id} and #{y_id} together; " \
          "draft #{other_id} still holds #{w_id}"

      clean_up(tenant, other_id, ids.all)
    end

    # --- held: the failed save and the two removals ----------------------

    # The rate the invoice editor offers, once it offers all three entries.
    def candidate_rate(tenant, ids)
      eventually("the candidates offer entries #{ids.all}") do
        offered = candidates(tenant)
        offered[ids.direct] if ids.all.all? { |id| offered.key?(id) }
      end.fetch("rate")
    end

    def save_drafts(tenant, ids, both_lines, other_line)
      draft_id = save_draft(tenant, number(tenant), both_lines)
      other_id = save_draft(tenant, other_number(tenant), [other_line])
      expect_reserved_ids!(tenant, held: ids.all, offered: [], after: "saving drafts #{draft_id} and #{other_id}")
      kept, linked, other = ids.all
      say "#{tenant[:name]}: draft #{draft_id} holds entry #{kept} directly and #{kept}, #{linked} through a grouped line; " \
          "draft #{other_id} holds #{other}"
      draft_id
    end

    def lines_back(tenant, draft_id, ids, both_lines)
      update!(tenant, draft_id, both_lines, "put both lines back on draft #{draft_id}")
      kept, linked, = ids.all
      expect_lines!(tenant, draft_id, [kept, linked])
      expect_reserved_ids!(tenant, held: ids.all, offered: [], after: "putting both lines back on draft #{draft_id}")
      say "#{tenant[:name]}: both lines are back on draft #{draft_id}, and entries #{kept} and #{linked} are reserved again"
    end

    # F1: the save adds W, which the second draft holds, so the owner refuses
    # the whole desired set and the invoice is not written. The removal of
    # the grouped line posted with it does not happen either.
    def refused_save(tenant, draft_id, ids, other_line)
      response = update(tenant, draft_id, [{ id: grouped_line_id(tenant, draft_id), _destroy: "1" }, other_line])
      expected = I18n.t("invoices.reservation.refused.on_other_invoice", entry_id: ids.other)
      unless response.status == 422 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: a save of draft #{draft_id} adding entry #{ids.other}, which another draft holds, answered " \
              "#{response.status} #{response.body.to_s.truncate(500)}, not 422 #{expected.inspect}"
      end

      expect_lines!(tenant, draft_id, [ids.direct, ids.linked])
      expect_reserved_ids!(tenant, held: ids.all, offered: [], after: "the refused save of draft #{draft_id}")
      say "#{tenant[:name]}: a save of draft #{draft_id} adding entry #{ids.other} was refused (F1), and changed nothing"
    end

    def removals(tenant, draft_id, ids)
      kept, released, other = ids.all
      update!(tenant, draft_id, [{ id: grouped_line_id(tenant, draft_id), _destroy: "1" }], "remove the grouped line of draft #{draft_id}")
      expect_lines!(tenant, draft_id, [kept])
      expect_reserved_ids!(tenant, held: [kept, other], offered: [released], after: "removing the grouped line of draft #{draft_id}")
      say "#{tenant[:name]}: removing the grouped line kept entry #{kept}, which the direct line references, and released #{released} (F3)"

      direct_id = line_ids(draft_id).fetch(:direct).sole
      update!(tenant, draft_id, [{ id: direct_id, _destroy: "1" }], "remove the direct line of draft #{draft_id}")
      expect_lines!(tenant, draft_id, [])
      expect_reserved_ids!(tenant, held: [other], offered: [kept, released], after: "removing the direct line of draft #{draft_id}")
      say "#{tenant[:name]}: removing the remaining direct line released entry #{kept}"
    end

    # --- restored: what outlived the failures, and the clean-up ----------

    def ensure_held_through_failures!(tenant, draft_id, ids)
      expect_reserved_ids!(tenant, held: ids.all, offered: [], after: "the failed save and destroy of draft #{draft_id}")
      eventually("the invoice operation worker delivers the aborts of draft #{draft_id}'s failed operations") do
        !Timekeeping::InvoiceOperation.undelivered.exists?(invoice_id: draft_id)
      end
      say "#{tenant[:name]}: entries #{ids.all} stayed reserved through the failures, and both aborts were delivered"
    end

    def clean_up(tenant, other_id, entry_ids)
      delete(tenant, :admin, "/api/v1/invoices/#{other_id}", "delete the draft #{other_id}")
      expect_reserved_ids!(tenant, held: [], offered: entry_ids, after: "deleting draft #{other_id}")
      entry_ids.each { |id| delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}") }
      eventually("entries #{entry_ids} leave the entry list and the candidates") do
        listed = entry_list(tenant).keys + candidates(tenant).keys
        entry_ids.none? { |id| listed.include?(id) }
      end
      say "#{tenant[:name]}: deleted draft #{other_id} and discarded entries #{entry_ids}"
    end

    # --- writes ---------------------------------------------------------

    def create_entry(tenant, letter, duration)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note: note(letter)))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note: note(letter))
    end

    def direct(entry, rate)
      { name: "Aggregate line direct", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
    end

    def grouped(entries, rate)
      { name: "Aggregate line grouped", date: Date.current.iso8601, linked_timesheet_entry_ids: entries.map(&:id),
        quantity: entries.sum(&:duration), rate: }
    end

    def save_draft(tenant, invoice_number, lines)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number:, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: lines
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{invoice_number}")
      response.json.fetch("id")
    end

    def update(tenant, draft_id, lines)
      as(tenant, :admin).call(:patch, "/api/v1/invoices/#{draft_id}", body: { invoice: { invoice_line_items_attributes: lines } })
    end

    def update!(tenant, draft_id, lines, what)
      expect_ok!(update(tenant, draft_id, lines), what)
    end

    # A bulk delete of one invoice is its hard destroy (§1.4).
    def destroy!(tenant, draft_id)
      response = as(tenant, :admin).call(:post, BULK_DELETE, body: { invoices_ids: [draft_id] })
      unless response.status == 204
        fail! "#{tenant[:name]}: the bulk delete of draft #{draft_id} answered #{response.status} #{response.body.to_s.truncate(500)}"
      end
      fail! "#{tenant[:name]}: draft #{draft_id} is still there after its bulk delete" if Invoice.with_discarded.exists?(draft_id)
    end

    # --- reads ----------------------------------------------------------

    # The run's kept draft, and the two entries its lines reference.
    def find_draft(tenant)
      draft_id = kept_draft_id(tenant, number(tenant))
      lines = line_ids(draft_id)
      x_id = lines.fetch(:direct_entries).first
      y_id = (lines.fetch(:linked_entries) - [x_id]).first
      unless lines.fetch(:direct).one? && lines.fetch(:grouped).one? && x_id && y_id
        fail! "#{tenant[:name]}: draft #{draft_id} does not hold one direct and one grouped line for two entries; " \
              "run the held step first"
      end

      [draft_id, x_id, y_id]
    end

    def find_other_draft(tenant)
      other_id = kept_draft_id(tenant, other_number(tenant))
      w_id = Timekeeping::InvoiceDesiredSet.referenced(Invoice.find(other_id)).sole
      [other_id, w_id]
    end

    def kept_draft_id(tenant, invoice_number)
      Invoice.kept.where(company: tenant[:company], invoice_number:, status: "draft").pick(:id) ||
        fail!("#{tenant[:name]}: no kept draft #{invoice_number}; run the held step first")
    end

    # The draft's lines, direct and grouped, and the entries each kind
    # references, from this application's invoice tables.
    def line_ids(draft_id)
      lines = Timekeeping::InvoiceDesiredSet.lines_of(Invoice.find(draft_id))
      direct, grouped = lines.partition(&:timesheet_entry_id)
      {
        direct: direct.map(&:id), grouped: grouped.map(&:id),
        direct_entries: direct.map(&:timesheet_entry_id), linked_entries: grouped.flat_map(&:linked_ids)
      }
    end

    def grouped_line_id(tenant, draft_id)
      line_ids(draft_id).fetch(:grouped).first || fail!("#{tenant[:name]}: draft #{draft_id} has no grouped line")
    end

    # --- checks ---------------------------------------------------------

    def expect_lines!(tenant, draft_id, entry_ids)
      held = Timekeeping::InvoiceDesiredSet.referenced(Invoice.find(draft_id))
      return if held == entry_ids.sort

      fail! "#{tenant[:name]}: draft #{draft_id} references entries #{held}, not #{entry_ids.sort}"
    end

    # Waits until the candidates leave out every held entry and offer every
    # other one at once: a release lands only when its commit is delivered.
    def expect_reserved_ids!(tenant, held:, offered:, after:)
      eventually("after #{after}, the candidates leave out entries #{held} and offer #{offered}") do
        shown = candidates(tenant)
        held.none? { |id| shown.key?(id) } && offered.all? { |id| shown.key?(id) }
      end
    end

    # Timekeeping stopped: the candidates, read from it, answer 503.
    def ensure_timekeeping_down!(tenant)
      response = as(tenant, :admin).call(:get, "/api/v1/invoices/line_items?client_id=#{tenant[:project].client_id}")
      return if response.status == 503

      fail! "#{tenant[:name]}: the invoice candidates answered #{response.status} while Timekeeping should be stopped, " \
            "so nothing would fail (stop timekeeping-web first; bin/timekeeping-demo aggregate-line does)"
    end

    def expect_unavailable!(tenant, response, what)
      expected = I18n.t("invoices.reservation.unavailable")
      return if response.status == 503 && response.json["errors"] == expected

      fail! "#{tenant[:name]}: #{what} answered #{response.status} #{response.body.to_s.truncate(500)}, " \
            "not 503 #{expected.inspect}"
    end

    # §9.2 step 4: each failure is recorded `failed`, which queues its abort.
    def expect_failed_intents!(tenant, draft_id)
      last = Timekeeping::InvoiceOperation.where(invoice_id: draft_id).order(:created_at, :id).last(2)
      return if last.map { |intent| [intent.kind, intent.state] } == [%w[save failed], %w[destroy failed]]

      fail! "#{tenant[:name]}: the ledger's last operations of draft #{draft_id} are " \
            "#{last.map { |intent| "#{intent.kind} #{intent.state}" }}, not a failed save and a failed destroy"
    end
end
