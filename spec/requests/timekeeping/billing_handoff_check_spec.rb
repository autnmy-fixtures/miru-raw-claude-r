# frozen_string_literal: true

require "rails_helper"

# The billing-handoff proof (Timekeeping::BillingHandoffCheck; docs/
# architecture/timekeeping-soa.md §12.4, "Billing writes during a handoff"),
# run in process through the real controllers on two tenants. These examples
# pin the handoff it names for each owner, the refused step (with the handoff
# stopped after its step 1: this copy closed, Timekeeping stopped, the
# journal holding the snapshot the close took) and the resumed step, and that
# each check fails the run when what it checks does not hold. The paused step
# needs other connections, so spec/models/timekeeping/billing_handoff_paused_spec.rb
# covers it. Against the two running applications it runs as
# bin/timekeeping-demo billing-handoff.
RSpec.describe Timekeeping::BillingHandoffCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Billing handoff business #{index + 1}")
      tenant.admin.update!(password:, password_confirmation: password)
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:directory) { Dir.mktmpdir("billing-handoff") }
  let(:journal_path) { Pathname(directory).join("rollback.json") }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T120000Z-ab12" }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      [response.status, response.content_type.to_s, response.body]
    end
  end

  def check
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run: run_name,
      logger: Logger.new(log),
      options: described_class::Options.new(wait: 2, tenants:, directory:, journals: { "timekeeping" => journal_path.to_s })
    )
  end

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
    FileUtils.rm_rf(directory)
  end

  before { tenants }

  # What the paused step leaves: on each tenant a sent invoice of the run with
  # its line, tax and a partial payment, and the run's state.
  def paused_write!(generation: 1)
    invoices = [tenant_a, tenant_b].map do |tenant|
      invoice = Invoice.create!(
        company: tenant.company, client: tenant.client, invoice_number: "BWH-#{tenant.company.id}-#{run_name}", status: :sent,
        issue_date: Date.current, due_date: Date.current + 30, currency: tenant.company.base_currency,
        invoice_line_items_attributes: [described_class::LINE.merge(date: Date.current)],
        invoice_taxes_attributes: [described_class::TAX]
      )
      InvoicePayment::Settle.process(
        { invoice_id: invoice.id, transaction_date: Date.current, transaction_type: "bank_transfer", amount: described_class::PAYMENT },
        invoice
      )
      { "company_id" => tenant.company.id, "invoice_id" => invoice.id, "tax_id" => invoice.invoice_taxes.sole.id,
        "line_id" => invoice.invoice_line_items.sole.id }
    end
    Pathname(directory).join(run_name).tap(&:mkpath).join("state.json")
      .write(JSON.generate({ "owner" => "timekeeping", "generation" => generation, "invoices" => invoices }))
    invoices
  end

  # The handoff's step 1 done: this copy closed at the raised generation, the
  # snapshot it took kept in its journal.
  def handoff_stopped_after_close!(snapshot: Timekeeping::FinancialSnapshot.process)
    set_timekeeping_ownership!(generation: 2, owner: "timekeeping", state: "closed")
    Timekeeping::RollbackJournal.new(path: journal_path).record(Timekeeping::Rollback::Resume.new(financial_snapshot: snapshot))
  end

  # A stopped timekeeping-web: every connection to it is refused.
  def stop_timekeeping!
    WebMock::API.stub_request(:any, TimekeepingContracts::FakeTimekeeping::SERVED).to_raise(Errno::ECONNREFUSED)
  end

  def billing_counts = [Invoice, InvoiceLineItem, InvoiceTax, Payment].map(&:count)

  describe "#handoff" do
    {
      "cut over to Timekeeping" => "timekeeping:rollback",
      "rolled back to the prepared application" => "timekeeping:recutover",
      "first handoff aborted" => "timekeeping:first_cutover"
    }.each do |state, task|
      it "names #{task} when #{state}" do
        set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch(state))

        expect(check.handoff).to eq(task)
      end
    end

    it "fails while a handoff has admission closed" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen"))

      expect { check.handoff }.to raise_error(described_class::Failed, /starts with admission open, under any owner; ownership is generation 2/)
    end
  end

  describe "#refused" do
    before do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
      paused_write!
    end

    it "sees an invoice create, an invoice update and a payment refused with 503 ownership-moving on both tenants, and nothing changed" do
      handoff_stopped_after_close!
      stop_timekeeping!
      before = billing_counts

      check.refused

      expect(billing_counts).to eq(before)
      expect(Invoice.where("invoice_number LIKE ?", "%-REFUSED")).to be_empty
      expect(log.string).to include(
        "the financial snapshot the handoff took after its close holds the paused write's invoices, lines and taxes",
        "Billing handoff business 1: an invoice create, an update of invoice",
        "Billing handoff business 2: an invoice create, an update of invoice",
        "while the handoff runs, invoice, line-item, invoice-tax and payment writes were refused with 503 ownership-moving " \
        "and changed nothing, on 2 businesses"
      )
    end

    it "fails when the handoff's snapshot was taken before the paused write committed" do
      snapshot = Timekeeping::FinancialSnapshot.process
      snapshot["invoices"].delete(Invoice.where("invoice_number LIKE 'BWH-%'").first.id.to_s)
      handoff_stopped_after_close!(snapshot:)

      expect { check.refused }.to raise_error(described_class::Failed, /financial snapshot does not hold invoice/)
    end

    it "fails when no handoff stands after its step 1" do
      expect { check.refused }.to raise_error(described_class::Failed, /stopped after its step 1, closed under timekeeping at generation 2/)
    end

    # With the billing-write fence let through, the invoice writes are still
    # refused by the invoice reservation boundary's own check, but nothing
    # else stops the payment.
    it "fails when a billing write is accepted" do
      handoff_stopped_after_close!
      allow(Timekeeping::Ownership).to receive(:admit!).and_wrap_original do |original|
        original.call
      rescue Timekeeping::Ownership::Moving
        Timekeeping::Ownership.current
      end

      expect { check.refused }.to raise_error(described_class::Failed, /business 1: a payment on invoice \d+ answered 201/)
    end
  end

  describe "#resumed" do
    let!(:invoices) { paused_write! }

    it "sees a payment accepted again on both tenants once the incoming owner holds the entries" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))

      check.resumed

      expect(Invoice.find(invoices.pluck("invoice_id")).map { |invoice| [invoice.payments.count, invoice.amount_due] })
        .to all(eq([2, 120]))
      expect(log.string).to include(
        "(2 payments now)",
        "once the handoff finished (generation 2, owner monolith, state open), a payment was accepted again on 2 businesses"
      )
    end

    it "fails while the handoff has not finished" do
      handoff_stopped_after_close!

      expect { check.resumed }.to raise_error(described_class::Failed, /monolith owning the entries with admission open at generation 2/)
    end
  end

  it "fails a step that finds no paused write for its run" do
    expect { check.refused }.to raise_error(described_class::Failed, /no paused billing write for run #{run_name}/)
  end
end
