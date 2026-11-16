# frozen_string_literal: true

# The billing-writes-during-a-handoff proof of docs/architecture/
# timekeeping-soa.md §12.4 (§10.1, §10.5 step 1), against the two running
# applications of the local demo (§11.2):
#
#   Billing writes during a handoff. With a billing write paused inside its
#   transaction, start a handoff: step 1 waits until the write commits or
#   aborts. While the handoff runs, invoice, line-item, invoice-tax and
#   payment writes are refused with 503 ownership-moving.
#
# It runs under any owner with admission open, and runs the handoff that owner
# hands over with (HANDOFFS): the first cutover from `legacy`, the rollback
# from `timekeeping`, the re-cutover from `monolith`. bin/timekeeping-demo
# billing-handoff drives it in four steps, all under one run name (RUN):
#
#   handoff  prints the handoff task to run (timekeeping:first_cutover,
#            timekeeping:rollback or timekeeping:recutover)
#   paused   the billing write: in one transaction, on each seeded business, a
#            sent invoice of the run with a line item and an invoice tax, and
#            a partial payment on it (InvoicePayment::Settle, as the payments
#            API records one). Every one of them passes the billing-write fence
#            (Timekeeping::BillingWriteFence), so the transaction holds the
#            ownership row FOR SHARE. It then writes `admitted` in the run's
#            directory and stays open. The script starts the handoff task
#            meanwhile; this step waits until that handoff's step 1, the
#            close's FOR UPDATE of the ownership row, is blocked by this very
#            transaction (pg_blocking_pids), checks that the ownership record
#            is still open at the generation it admitted, and writes
#            `waiting`. Once the script writes `release`, it commits, and then
#            the handoff closes admission at the next generation
#   refused  with the handoff interrupted right after its step 1 (the script
#            stops timekeeping-web before the release, so the next step, which
#            closes Timekeeping's copy, cannot be reached, and the run stops
#            for a resume): this copy is closed at the raised generation, and
#            the financial snapshot the handoff took once its close had
#            drained the paused write (its journal's) holds the run's invoices
#            and taxes as committed. Then, on each business, over the public
#            API as its admin: an invoice create with a line item and a tax,
#            an update of the run's invoice changing its line item's rate and
#            its tax, and a payment on it each answer 503 with the
#            ownership-moving message, and no invoice, line-item, invoice-tax
#            or payment row changes
#   resumed  once the script has started timekeeping-web again and the handoff
#            task has resumed and finished: the incoming owner holds the
#            entries with admission open at the raised generation, and a
#            payment on each run's invoice is accepted again
#
# What each step needs from the one before sits in the run's directory under
# tmp/timekeeping (the miru_handoff_journals volume, which every process of
# the existing application shares): `state.json` (the generation and owner
# the paused write was admitted under, and the run's invoices), and the
# three markers. Any check that does not hold raises Failed. If the paused
# write fails before `release`, it rolls back, and the handoff it held then
# runs on; a step that fails leaves the handoff where it stands, for its task
# to resume or abort. A run that finishes leaves, per business, one sent
# invoice of the run with two partial payments, and the handoff done.
class Timekeeping::BillingHandoffCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  # The handoff each outgoing owner hands over with, the journal its task
  # keeps, and the owner it hands over to.
  Handoff = Data.define(:task, :journal, :incoming)

  HANDOFFS = {
    "legacy" => Handoff.new(task: "timekeeping:first_cutover", journal: Timekeeping::FirstCutoverJournal, incoming: "timekeeping"),
    "timekeeping" => Handoff.new(task: "timekeeping:rollback", journal: Timekeeping::RollbackJournal, incoming: "monolith"),
    "monolith" => Handoff.new(task: "timekeeping:recutover", journal: Timekeeping::RecutoverJournal, incoming: "timekeeping")
  }.freeze

  DIRECTORY = "tmp/timekeeping/billing-handoff"

  # The run's invoice: one line of two hours at 100, and a 10% tax, so 220.
  LINE = { name: "Billing handoff line", rate: 100, quantity: 120 }.freeze
  TAX = { name: "Billing handoff tax", calculation_method: "percentage", value: 10 }.freeze
  PAYMENT = 50

  BILLING = [Invoice, InvoiceLineItem, InvoiceTax, Payment].freeze

  # The handoff's step 1, as Timekeeping::HandoffFence sends it: the
  # ownership row read FOR UPDATE.
  CLOSE_QUERY = /timekeeping_ownerships.*FOR UPDATE/im

  # What a run may change: wait is how long, in seconds, a step waits on
  # another process; tenants default to the seeded businesses; directory is
  # where the runs keep their markers, and journals the path of a handoff's
  # journal by outgoing owner, where it is not the task's default.
  Options = Data.define(:wait, :tenants, :directory, :journals) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS, directory: DIRECTORY, journals: {}) = super
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

  # The handoff task the current owner hands over with.
  def handoff
    HANDOFFS.fetch(ensure_open!.owner).task
  end

  # The billing write, paused inside its transaction until the handoff's
  # step 1 waits on it and the script releases it.
  def paused
    ownership = ensure_open!
    directory.mkpath
    Invoice.transaction do
      admitted = Timekeeping::Ownership.lock_shared!
      invoices = @options.tenants.map { |tenant| paused_write(prepare_tenant(tenant)) }
      write_state(owner: admitted.owner, generation: admitted.generation, invoices:)
      hold_until_released(admitted)
    end
    closed = expect_closed_after_release!(ownership)
    say "the paused billing write committed, and only then did the handoff close admission " \
        "(#{closed.summary}), on #{@options.tenants.size} businesses"
  end

  # With the handoff stopped after its step 1.
  def refused
    state = read_state
    expect_in_handoff!(state)
    expect_snapshot_holds!(state)
    @options.tenants.each { |tenant| check_refused(prepare_tenant(tenant), state) }
    say "while the handoff runs, invoice, line-item, invoice-tax and payment writes were refused with 503 " \
        "ownership-moving and changed nothing, on #{@options.tenants.size} businesses"
  end

  # Once the handoff has resumed and finished.
  def resumed
    state = read_state
    ownership = expect_handed_over!(state)
    @options.tenants.each { |tenant| check_resumed(prepare_tenant(tenant), state) }
    say "once the handoff finished (#{ownership.summary}), a payment was accepted again on #{@options.tenants.size} businesses"
  end

  private

    def log_prefix = "billing handoff"

    def wait = @options.wait

    def ensure_open!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.state_open?

      fail! "the billing-handoff proof starts with admission open, under any owner; ownership is #{ownership.summary} " \
            "(finish or abort the handoff in progress first)"
    end

    def directory = Rails.root.join(@options.directory, @run)

    def marker(name) = directory.join(name)

    def number(tenant) = "BWH-#{tenant[:company].id}-#{@run}"

    # --- paused: the billing write ---------------------------------------

    # A sent invoice with a line and a tax, then a partial payment, through
    # the models and the payment service the API uses. Answers what later
    # steps need of it.
    def paused_write(tenant)
      invoice = Invoice.create!(
        company: tenant[:company], client: tenant[:project].client, invoice_number: number(tenant), status: :sent,
        issue_date: Date.current, due_date: Date.current + 30, currency: tenant[:company].base_currency,
        invoice_line_items_attributes: [LINE.merge(date: Date.current)], invoice_taxes_attributes: [TAX]
      )
      InvoicePayment::Settle.process(
        { invoice_id: invoice.id, transaction_date: Date.current, transaction_type: "bank_transfer", amount: PAYMENT,
          name: "Billing handoff #{@run}" },
        invoice
      )
      say "#{tenant[:name]}: paused inside its transaction: invoice #{invoice.id} (#{invoice.amount}), " \
          "its line and tax, and a payment of #{PAYMENT}"
      { "company_id" => tenant[:company].id, "invoice_id" => invoice.id, "tax_id" => invoice.invoice_taxes.sole.id,
        "line_id" => invoice.invoice_line_items.sole.id }
    end

    def hold_until_released(admitted)
      pid = Invoice.connection.select_value("SELECT pg_backend_pid()")
      marker("admitted").write("#{pid}\n")
      say "admitted under #{admitted.summary}, holding the ownership row FOR SHARE (backend #{pid}); start the handoff"

      handoff_pid = eventually("the handoff's step 1 waits on this billing write (backend #{pid})") { blocked_close(pid) }
      seen = Timekeeping::Ownership.current
      unless seen.generation == admitted.generation && seen.state_open?
        fail! "while the handoff waits on the paused billing write, ownership reads #{seen.summary}, " \
              "not still open at generation #{admitted.generation}"
      end
      marker("waiting").write("#{handoff_pid}\n")
      say "the handoff's close (backend #{handoff_pid}) waits on this billing write, and ownership is still " \
          "#{seen.summary}; waiting for the release"

      eventually("the release (#{marker('release')})") { marker("release").exist? }
    end

    # The backend running the handoff's close, when it is blocked by `pid`.
    # Read from inside the paused transaction, which holds the activity
    # statistics it first read until it ends, so each read clears them first.
    # The ownership record read there is the latest committed one too: a
    # read-committed transaction reads each statement afresh.
    def blocked_close(pid)
      connection = Invoice.connection
      connection.execute("SELECT pg_stat_clear_snapshot()")
      connection.select_rows(<<~SQL.squish).find { |_, query| query.match?(CLOSE_QUERY) }&.first
        SELECT pid, query FROM pg_stat_activity
        WHERE #{Integer(pid)} = ANY(pg_blocking_pids(pid)) AND wait_event_type = 'Lock'
      SQL
    end

    def expect_closed_after_release!(before)
      eventually("the handoff closes admission at generation #{before.generation + 1}") do
        current = Timekeeping::Ownership.current
        current if current.generation == before.generation + 1 && !current.state_open?
      end
    end

    # --- refused: billing writes while the handoff runs ------------------

    def expect_in_handoff!(state)
      ownership = Timekeeping::Ownership.current
      return if ownership.owner == state["owner"] && ownership.state_closed? && ownership.generation == state["generation"] + 1

      fail! "the refused step runs while the handoff is stopped after its step 1, closed under #{state['owner']} at " \
            "generation #{state['generation'] + 1}; ownership is #{ownership.summary}"
    end

    # The handoff's "before" of the money check (§13 item 2), taken once its
    # close had drained the paused write: it must hold what that write
    # committed.
    def expect_snapshot_holds!(state)
      kind = HANDOFFS.fetch(state["owner"]).journal
      journal = kind.new(path: @options.journals.fetch(state["owner"], kind::DEFAULT_PATH))
      snapshot = journal.resume.financial_snapshot || fail!("the handoff's journal #{journal.path} holds no financial snapshot")
      state["invoices"].each do |written|
        invoice = Invoice.find(written["invoice_id"])
        held = snapshot.dig("invoices", invoice.id.to_s)
        unless held && held["amount"].to_d == invoice.amount && held["outstanding_amount"].to_d == invoice.outstanding_amount &&
            snapshot.dig("invoice_taxes", written["tax_id"].to_s) && snapshot.dig("invoice_line_items", written["line_id"].to_s)
          fail! "the handoff's financial snapshot does not hold invoice #{invoice.id} with its line and tax as the paused " \
                "write committed them: #{held.inspect}"
        end
      end
      say "the financial snapshot the handoff took after its close holds the paused write's invoices, lines and taxes"
    end

    def check_refused(tenant, state)
      invoice = run_invoice(tenant, state)
      admin = as(tenant, :admin)
      expect_refused!(tenant, "an invoice create with a line item and a tax") do
        admin.call(:post, "/api/v1/invoices", body: { invoice: new_invoice(tenant) })
      end
      expect_refused!(tenant, "an update of invoice #{invoice.id}'s line item and tax") do
        admin.call(:patch, "/api/v1/invoices/#{invoice.id}", body: { invoice: changed_invoice(invoice) })
      end
      expect_refused!(tenant, "a payment on invoice #{invoice.id}") { pay(admin, invoice) }
      say "#{tenant[:name]}: an invoice create, an update of invoice #{invoice.id}'s line and tax, and a payment on it " \
          "were each refused with 503 ownership-moving, and no billing row changed"
    end

    def new_invoice(tenant)
      {
        client_id: tenant[:project].client_id, invoice_number: "#{number(tenant)}-REFUSED", status: "sent",
        issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601, currency: tenant[:company].base_currency,
        invoice_line_items_attributes: [LINE.merge(date: Date.current.iso8601)], invoice_taxes_attributes: [TAX]
      }
    end

    def changed_invoice(invoice)
      line = invoice.invoice_line_items.sole
      tax = invoice.invoice_taxes.sole
      {
        client_id: invoice.client_id, invoice_number: invoice.invoice_number, issue_date: invoice.issue_date.iso8601,
        due_date: invoice.due_date.iso8601, currency: invoice.currency,
        invoice_line_items_attributes: [{ id: line.id, rate: line.rate + 1 }],
        invoice_taxes_attributes: [{ id: tax.id, value: tax.value + 1 }]
      }
    end

    def pay(admin, invoice)
      admin.call(:post, "/api/v1/payments", body: {
        payment: { invoice_id: invoice.id, transaction_date: Date.current.iso8601, transaction_type: "bank_transfer", amount: PAYMENT }
      })
    end

    def expect_refused!(tenant, what)
      before = billing_rows
      response = yield
      expected = I18n.t("timesheet_entry.ownership_moving")
      unless response.status == 503 && response.json["errors"] == expected
        fail! "#{tenant[:name]}: #{what} answered #{response.status} #{response.body.to_s.truncate(500)}, " \
              "not 503 #{expected.inspect}"
      end
      fail! "#{tenant[:name]}: #{what} was refused, but changed a billing row" unless billing_rows == before
    end

    def billing_rows
      BILLING.to_h { |model| [model.name, model.unscoped.order(:id).map(&:attributes)] }
    end

    # --- resumed: the handoff done ---------------------------------------

    def expect_handed_over!(state)
      incoming = HANDOFFS.fetch(state["owner"]).incoming
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == incoming && ownership.state_open? && ownership.generation == state["generation"] + 1

      fail! "the resumed step runs once the handoff has finished, #{incoming} owning the entries with admission open at " \
            "generation #{state['generation'] + 1}; ownership is #{ownership.summary}"
    end

    def check_resumed(tenant, state)
      invoice = run_invoice(tenant, state)
      paid = invoice.payments.count
      response = pay(as(tenant, :admin), invoice)
      unless response.status == 201 && invoice.payments.count == paid + 1
        fail! "#{tenant[:name]}: a payment on invoice #{invoice.id} answered #{response.status} " \
              "#{response.body.to_s.truncate(500)} once the handoff finished, and was not recorded"
      end
      say "#{tenant[:name]}: a payment on invoice #{invoice.id} was accepted again (#{paid + 1} payments now)"
    end

    # --- the run's state ---------------------------------------------------

    def write_state(owner:, generation:, invoices:)
      marker("state.json").write(JSON.generate({ "owner" => owner, "generation" => generation, "invoices" => invoices }))
    end

    def read_state
      path = marker("state.json")
      fail! "no paused billing write for run #{@run} (#{path}); run the paused step first" unless path.exist?

      JSON.parse(path.read)
    end

    def run_invoice(tenant, state)
      written = state["invoices"].find { |row| row["company_id"] == tenant[:company].id } ||
        fail!("#{tenant[:name]}: the paused billing write of run #{@run} wrote no invoice here")
      Invoice.find(written["invoice_id"])
    end
end
