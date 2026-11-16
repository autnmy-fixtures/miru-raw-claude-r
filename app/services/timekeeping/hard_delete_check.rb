# frozen_string_literal: true

# The hard-delete-of-a-non-draft part of docs/architecture/timekeeping-soa.md
# §12.4's failure injection, against the two running applications of the
# local demo (§11.2): the last row of §9.3, and §13 item 6's "a failed and a
# successful hard delete of a non-draft invoice".
#
#   Hard delete of a non-draft fails: prior state unchanged (§9.3).
#
#   A destroyed non-draft keeps its reservations as retained; the
#   reservation itself carries the owner. A failed delete leaves the prior
#   state as it was. A successful delete keeps the edit lock and allows the
#   same provisional successor as above (§7.3, §7.2's "destroy | non-draft"
#   and "holds a retained reservation by another invoice" rows).
#
# It runs while Timekeeping or the prepared application (after a rollback)
# owns the entries with admission open, in one step: nothing is stopped or
# started. A bulk delete is the hard destroy (§1.4), and it fails the way it
# fails for a user: the invoice has a recorded payment, so the destroy is
# refused inside the invoice transaction, after the owner prepared it. On
# each seeded business, over the public API as its users
# (Timekeeping::PublicApi):
#
#   held       the employee creates entries X and Y. The admin saves a draft
#              holding X and one holding Y, which locks both (L1), then marks
#              each sent: a non-draft save that keeps its entries, and their
#              edit locks. The admin records a partial payment on X's invoice
#   failed     a bulk delete of X's invoice answers 422 with the
#              recorded-payments message. The invoice, its line and its
#              payment are still there, the ledger records the destroy failed
#              and delivers its abort, and X is as it was on its owner
#              (version, `locked`, `updated_at`): still reserved, and still
#              locked against the employee, whose edit is refused
#   succeeded  a bulk delete of Y's invoice answers 204 and the invoice is
#              gone. The ledger records the destroy succeeded and delivers its
#              commit. Y keeps its edit lock (the employee's edit is still
#              refused), and the candidates offer it again (L3): the
#              reservation is retained, not active
#   successor  the admin saves a draft holding Y, which is accepted: a
#              retained reservation does not refuse a provisional successor
#              (F1 does not apply). Once its commit is delivered, the admin
#              deletes that draft (F2 releases it), and Y is unlocked, so the
#              employee's edit goes through: the successor's commit removed
#              the retained reservation, which would otherwise still lock Y.
#              Then the employee discards Y
#
# The edit lock is read twice: as the owner holds it, through the entry
# reads under the current owner (Timekeeping::EntryReads), and as the
# employee meets it, an edit refused with today's message. Reservations are
# read where the invoice editor reads them, the candidates (§3.3). Any check
# that does not hold raises Failed. A run that finishes leaves, per business,
# X's sent invoice with its payment, holding X, which cannot be hard-deleted;
# one discarded draft; and Y discarded. One that fails leaves what it wrote
# for inspection.
class Timekeeping::HardDeleteCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # The two entries of a run: X, on the invoice whose delete fails; Y, on the
  # one whose delete succeeds.
  DURATIONS = { "X" => 25.0, "Y" => 35.0 }.freeze

  # The owners that hold reservations, and so have a non-draft to destroy.
  OWNERS = %w[timekeeping monolith].freeze

  BULK_DELETE = "/api/v1/invoices/bulk_deletion"

  # The payment recorded on X's invoice; less than its amount, so it stays
  # partially paid.
  PAYMENT = 1

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

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
    ownership = ensure_owner_holds_reservations!
    @options.tenants.each { |tenant| check_tenant(prepare_tenant(tenant)) }
    say "a failed hard delete of a non-draft left it and its reservation as they were, and a successful one kept the " \
        "edit lock and let a successor take the entry over, on #{@options.tenants.size} businesses, under owner " \
        "#{ownership.owner} at generation #{ownership.generation}"
  end

  private

    def log_prefix = "hard delete"

    def wait = @options.wait

    def ensure_owner_holds_reservations!
      ownership = Timekeeping::Ownership.current
      return ownership if OWNERS.include?(ownership.owner) && ownership.state_open?

      fail! "the hard-delete proof runs while Timekeeping or the prepared application owns the entries with admission " \
            "open (after a cutover or a rollback); ownership is #{ownership.summary}"
    end

    def note(letter) = "Hard delete #{@run} #{letter}"

    def number(tenant, letter) = "HDL-#{tenant[:company].id}-#{@run}-#{letter}"

    def check_tenant(tenant)
      x, y = DURATIONS.map { |letter, duration| create_entry(tenant, letter, duration) }
      rate = candidate_rate(tenant, [x, y])
      x_invoice = held(tenant, x, rate)
      y_invoice = held(tenant, y, rate)
      pay!(tenant, x_invoice)

      failed(tenant, x_invoice, x)
      succeeded(tenant, y_invoice, y)
      successor(tenant, y, rate)
    end

    # --- held: two sent invoices, each holding one entry, locked -----------

    def candidate_rate(tenant, entries)
      ids = entries.map(&:id)
      eventually("the candidates of #{tenant[:name]} offer entries #{ids}") do
        offered = candidates(tenant)
        offered[ids.first] if ids.all? { |id| offered.key?(id) }
      end.fetch("rate")
    end

    # A draft holding the entry, which locks it (L1), then marked sent: a
    # non-draft save that keeps the entry, so its lock stays.
    def held(tenant, entry, rate)
      draft_id = save_draft(tenant, number(tenant, entry.note.split.last), entry, rate)
      response = as(tenant, :admin).call(:patch, "/api/v1/invoices/#{draft_id}", body: { invoice: { status: "sent" } })
      expect_ok!(response, "mark invoice #{draft_id} sent")
      invoice = Invoice.find(draft_id)
      fail! "#{tenant[:name]}: invoice #{draft_id} is #{invoice.status} after it was marked sent" unless invoice.sent?

      delivered!(tenant, latest_intent(draft_id), "save", "succeeded")
      held!(tenant, invoice, [entry.id], "marking invoice #{draft_id} sent")
      reserved!(tenant, entry, after: "marking invoice #{draft_id} sent")
      locked!(tenant, entry, true, after: "marking invoice #{draft_id} sent")
      say "#{tenant[:name]}: sent invoice #{draft_id} holds entry #{entry.id}, which stays locked against the employee"
      invoice
    end

    def pay!(tenant, invoice)
      response = as(tenant, :admin).call(:post, "/api/v1/payments", body: {
        payment: { invoice_id: invoice.id, transaction_date: Date.current.iso8601, transaction_type: "bank_transfer", amount: PAYMENT }
      })
      unless response.status == 201 && invoice.payments.count == 1
        fail! "#{tenant[:name]}: a payment on invoice #{invoice.id} answered #{response.status} #{response.body.to_s.truncate(500)}"
      end

      say "#{tenant[:name]}: recorded a payment of #{PAYMENT} on invoice #{invoice.id}"
    end

    # --- failed: the destroy refused after its prepare ---------------------

    def failed(tenant, invoice, entry)
      id = invoice.id
      what = "the failed delete of invoice #{id}"
      before = invoice_state(invoice)
      owner_before = owner_entry(tenant, entry.id)
      response = bulk_delete(tenant, invoice)
      expected = "Some invoices could not be deleted because they have recorded payments."
      unless response.status == 422 && response.json["error"] == expected && response.json["undeletable_invoice_ids"] == [id]
        fail! "#{tenant[:name]}: the bulk delete of invoice #{id}, which has a recorded payment, answered " \
              "#{response.status} #{response.body.to_s.truncate(500)}, not 422 #{expected.inspect} naming it"
      end

      intent = delivered!(tenant, latest_intent(id), "destroy", "failed")
      now = invoice_state(invoice)
      fail! "#{tenant[:name]}: #{what} changed it: #{before} became #{now}" unless now == before

      unchanged_entry!(tenant, entry, owner_before, what)
      reserved!(tenant, entry, after: what)
      edit_refused!(tenant, entry, after: what)
      say "#{tenant[:name]}: the bulk delete of invoice #{id} was refused with 422, as it has a recorded payment; " \
          "operation #{intent.operation_id} failed and its abort was delivered, and the invoice, its line, its payment " \
          "and entry #{entry.id} are as they were, still reserved and locked"
    end

    # --- succeeded: the destroy, and the retained reservation ---------------

    def succeeded(tenant, invoice, entry)
      id = invoice.id
      what = "the delete of invoice #{id}"
      response = bulk_delete(tenant, invoice)
      unless response.status == 204
        fail! "#{tenant[:name]}: the bulk delete of invoice #{id} answered #{response.status} #{response.body.to_s.truncate(500)}, not 204"
      end
      fail! "#{tenant[:name]}: invoice #{id} is still there after its bulk delete" if Invoice.with_discarded.exists?(id)

      intent = delivered!(tenant, latest_intent(id), "destroy", "succeeded")
      offered!(tenant, entry, after: what)
      locked!(tenant, entry, true, after: what)
      edit_refused!(tenant, entry, after: what)
      say "#{tenant[:name]}: the bulk delete of sent invoice #{id} went through, and its commit of operation " \
          "#{intent.operation_id} was delivered; entry #{entry.id} keeps its edit lock and is offered again (retained)"
    end

    # --- successor: a draft takes the retained entry over -------------------

    def successor(tenant, entry, rate)
      draft_id = save_draft(tenant, number(tenant, "S"), entry, rate)
      delivered!(tenant, latest_intent(draft_id), "save", "succeeded")
      reserved!(tenant, entry, after: "saving successor draft #{draft_id}")
      say "#{tenant[:name]}: successor draft #{draft_id} took entry #{entry.id} over from the deleted invoice"

      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the successor draft #{draft_id}")
      delivered!(tenant, latest_intent(draft_id, kind: "discard"), "discard", "succeeded")
      offered!(tenant, entry, after: "deleting draft #{draft_id}")
      locked!(tenant, entry, false, after: "deleting successor draft #{draft_id}")
      edit!(tenant, entry)
      discard!(tenant, entry)
      say "#{tenant[:name]}: deleting draft #{draft_id} unlocked entry #{entry.id}, so the successor's commit had removed " \
          "the retained reservation; the employee edited it, then discarded it"
    end

    # --- writes -------------------------------------------------------------

    def create_entry(tenant, letter, duration)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note: note(letter)))
      expect_ok!(response, "create entry #{letter} for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note: note(letter))
    end

    def save_draft(tenant, invoice_number, entry, rate)
      line = { name: entry.note, date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number:, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: [line]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{invoice_number}")
      response.json.fetch("id")
    end

    # A bulk delete of one invoice is its hard destroy (§1.4).
    def bulk_delete(tenant, invoice)
      as(tenant, :admin).call(:post, BULK_DELETE, body: { invoices_ids: [invoice.id] })
    end

    def edit_body(tenant, entry, note)
      { project_id: tenant[:project].id, timesheet_entry: { duration: entry.duration, work_date: Date.current.iso8601, note: } }
    end

    def edit(tenant, entry, note)
      as(tenant, :employee).call(:patch, "/api/v1/timesheet_entry/#{entry.id}", body: edit_body(tenant, entry, note))
    end

    def edit!(tenant, entry)
      expect_ok!(edit(tenant, entry, "#{entry.note} edited"), "edit entry #{entry.id} as the employee once it is released")
      edited = owner_entry(tenant, entry.id)
      fail! "#{tenant[:name]}: the employee's edit of entry #{entry.id} did not reach its owner" unless edited["note"] == "#{entry.note} edited"
    end

    def discard!(tenant, entry)
      id = entry.id
      delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}")
      eventually("entry #{id} leaves the entry list and the candidates") do
        !entry_list(tenant).key?(id) && !candidates(tenant).key?(id)
      end
    end

    # --- checks -------------------------------------------------------------

    # The employee meets the edit lock as today: 422 with the model's message,
    # and the entry unchanged on its owner.
    def edit_refused!(tenant, entry, after:)
      before = owner_entry(tenant, entry.id)
      response = edit(tenant, entry, "#{entry.note} refused")
      expected = "Cannot edit a locked timesheet entry. Please contact admin."
      unless response.status == 422 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: after #{after}, the employee's edit of entry #{entry.id} answered #{response.status} " \
              "#{response.body.to_s.truncate(500)}, not 422 #{expected.inspect}"
      end

      unchanged_entry!(tenant, entry, before, "the employee's refused edit after #{after}")
    end

    def locked!(tenant, entry, expected, after:)
      locked = owner_entry(tenant, entry.id).fetch("locked")
      return if locked == expected

      fail! "#{tenant[:name]}: after #{after}, entry #{entry.id} is #{locked ? 'locked' : 'not locked'} on its owner, " \
            "not #{expected ? 'locked' : 'unlocked'}"
    end

    def offered!(tenant, entry, after:)
      eventually("after #{after}, the candidates of #{tenant[:name]} offer entry #{entry.id}") { candidates(tenant).key?(entry.id) }
    end

    def reserved!(tenant, entry, after:)
      eventually("after #{after}, the candidates of #{tenant[:name]} leave out entry #{entry.id}") { !candidates(tenant).key?(entry.id) }
    end

    def held!(tenant, invoice, ids, after)
      referenced = Timekeeping::InvoiceDesiredSet.referenced(invoice.reload)
      return if referenced == ids

      fail! "#{tenant[:name]}: after #{after}, invoice #{invoice.id} references entries #{referenced}, not #{ids}"
    end

    def unchanged_entry!(tenant, entry, before, after)
      now = owner_entry(tenant, entry.id)
      return if now == before

      fail! "#{tenant[:name]}: #{after} changed entry #{entry.id} on its owner: #{before} became #{now}"
    end

    # Waits for the invoice operation worker to deliver the intent's commit or
    # abort, and checks what the save recorded.
    def delivered!(tenant, intent, kind, state)
      unless intent.kind == kind && intent.state == state
        fail! "#{tenant[:name]}: the ledger's last operation of invoice #{intent.invoice_id} is #{intent.kind} #{intent.state}, " \
              "not #{kind} #{state}"
      end

      eventually("the invoice operation worker delivers operation #{intent.operation_id} of invoice #{intent.invoice_id}") do
        intent.reload.delivered_at
      end
      intent
    end

    # --- reads --------------------------------------------------------------

    # What a failed delete must leave as it was: the invoice, its lines and
    # its payments.
    def invoice_state(invoice)
      invoice = Invoice.with_discarded.find_by(id: invoice.id)
      return {} unless invoice

      {
        invoice: invoice.attributes.slice("status", "amount", "outstanding_amount", "discarded_at", "updated_at"),
        lines: invoice.invoice_line_items.order(:id).map { |line| line.attributes.slice("id", "timesheet_entry_id", "rate", "quantity") },
        payments: invoice.payments.order(:id).pluck(:id, :amount)
      }
    end

    def latest_intent(invoice_id, kind: nil)
      scope = Timekeeping::InvoiceOperation.where(invoice_id:)
      scope = scope.where(kind:) if kind
      scope.order(:id).last || fail!("no operation of invoice #{invoice_id} in the invoice operation ledger")
    end

    # The entry as its owner holds it, read as the entry API's own reads read
    # it under the current owner (Timekeeping::EntryReads): the remote
    # Timekeeping's, or the prepared application's own table, each with the
    # `locked` its reservations derive (§7.1).
    def owner_entry(tenant, id)
      admin = User.find_by!(email: tenant[:admin])
      read = Timekeeping::EntryReads::Find.new(id:, company: tenant[:company], writer: "web")
      record = Current.set(user: admin, company: tenant[:company]) { Timekeeping::EntryReads.call(read) }
      { "note" => record.note, "version" => record.version, "locked" => record.locked, "updated_at" => record.updated_at&.utc&.iso8601(6) }
    end
end
