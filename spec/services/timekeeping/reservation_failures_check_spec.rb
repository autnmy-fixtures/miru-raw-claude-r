# frozen_string_literal: true

require "rails_helper"

# The reservation-protocol part of the failure injection (Timekeeping::
# ReservationFailuresCheck; docs/architecture/timekeeping-soa.md §12.4, §9.3),
# run in process through the real controllers and invoice writes on two
# tenants while Timekeeping owns the entries. Timekeeping is its consumer-side
# fake (FakeTimekeeping, for the entry and reservation APIs). The invoice
# operation worker runs after every request while `working` is on, as
# miru-jobs does, and not at all while it is off, as with miru-jobs stopped.
# Against the two running applications, bin/timekeeping-demo
# reservation-failures stops and starts miru-jobs between the two steps.
RSpec.describe Timekeeping::ReservationFailuresCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Reservation failures #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T190000Z-ef56" }
  let(:directory) { Dir.mktmpdir("reservation-failures") }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      Timekeeping::InvoiceOperationWorker.new.run if @working
      answer
    end
  end

  def check(tenants: self.tenants)
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run: run_name,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:, directory:)
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

  before do
    tenants
    set_timekeeping_ownership!(ownership)
    # The boundary's jitter between prepare attempts.
    allow_any_instance_of(Timekeeping::InvoiceBoundary).to receive(:sleep)
  end

  after { expect(fake.violations).to be_empty }

  def entries_of(tenant)
    fake.entries.select { |held| held["company_id"] == tenant.company.id }.index_by { |held| held["note"].split.last }
  end

  def draft_of(tenant)
    Invoice.with_discarded.where(company: tenant.company).where("invoice_number LIKE ?", "%RSF-#{tenant.company.id}-#{run_name}").sole
  end

  def calls(operation, intent)
    fake.calls.count { |call| call.operation == operation && call.params["operation_id"] == intent.operation_id }
  end

  def paused
    @working = false
    check.paused
  end

  # miru-jobs started again: it sweeps at once, then after every request.
  def resume_worker!
    @working = true
    Timekeeping::InvoiceOperationWorker.new.run
  end

  it "refuses the wrong-company and unresolved saves, and redelivers the lost commit without a second change, on both tenants" do
    paused

    [tenant_a, tenant_b].each do |tenant|
      draft = draft_of(tenant)
      intents = Timekeeping::InvoiceOperation.where(invoice_id: draft.id).order(:id).to_a
      expect(intents.map(&:state)).to eq(%w[succeeded failed failed failed])
      expect(intents.map(&:delivered_at)).to all(be_nil)
      # The unreachable update never reached the owner; both refused ones did.
      expect(intents.drop(1).map { |intent| calls(:prepare, intent) }).to eq([0, 1, 1])
      # The sweep sent each outcome once, and lost every answer.
      expect(calls(:commit, intents.first)).to eq(1)
      expect(intents.drop(1).map { |intent| calls(:abort, intent) }).to eq([1, 1, 1])
      expect(fake.holding(entries_of(tenant).fetch("X").fetch("id"))).to have_attributes(invoice_id: draft.id, state: :committed)
      expect(fake.holding(entries_of(tenant).fetch("Y").fetch("id"))).to be_nil
    end
    state = JSON.parse(File.read(File.join(directory, run_name, "state.json")))
    expect(state.keys).to eq(tenants.pluck(:name))
    expect(state.values.map { |tenant| tenant.fetch("operations").keys })
      .to all(eq(%w[committed wrong_company unreachable unresolved_in_process unresolved_over_api]))

    resume_worker!
    check.resumed

    [tenant_a, tenant_b].each do |tenant|
      draft = draft_of(tenant)
      expect(draft).to be_discarded
      intents = Timekeeping::InvoiceOperation.where(invoice_id: draft.id).order(:id).to_a
      # The draft, three failed updates, the retry, and the delete.
      expect(intents.map(&:state)).to eq(%w[succeeded failed failed failed succeeded succeeded])
      expect(intents.map(&:delivered_at)).to all(be_present)
      # Commit sent twice, the second answered its receipt.
      expect(calls(:commit, intents.first)).to eq(2)
      entries = entries_of(tenant)
      expect(entries.transform_values { |entry| entry["duration"] }).to eq("X" => 20.0, "Y" => 30.0, "W" => 40.0)
      expect(entries.values).to all(include("discarded_at" => be_present))
      expect(entries.values.map { |entry| fake.holding(entry.fetch("id")) }).to all(be_nil)
    end
    # The wrong-company saves wrote no invoice, and were aborted.
    wrong = Timekeeping::InvoiceOperation.where(kind: "save").where.not(invoice_id: [draft_of(tenant_a).id, draft_of(tenant_b).id])
    expect(wrong.map { |intent| [intent.state, intent.delivered_at.present?, Invoice.with_discarded.exists?(intent.invoice_id)] })
      .to eq([["failed", true, false]] * 2)
    expect(Timekeeping::InvoiceOperation.undelivered).to be_empty
    expect(log.string).to include(
      "belongs to another workspace, so the invoice was not saved.",
      "failed before its prepare was sent",
      "was refused as a retryable operation-unresolved",
      "the same update over the public API answered 409",
      "and every answer was lost; all of them stay undelivered",
      "on 2 businesses, at generation 1",
      "so the second commit changed nothing",
      "the client retried the update, and draft"
    )
  end

  it "fails when the invoice operation worker runs during the paused step, as nothing is then unresolved" do
    @working = true

    expect { check.paused }.to raise_error(described_class::Failed, /was delivered during the paused step, so the invoice operation worker runs/)
  end

  it "fails when the owner commits again on a resent commit, changing the entry" do
    paused
    original = fake.method(:commit_operation)
    allow(fake).to receive(:commit_operation) do |params, input, claims|
      entry = fake.entries.find { |held| held["note"] == "Reservation failures #{run_name} X" && held["company_id"] == tenant_a.company.id }
      # As a commit that ran its change again would leave it.
      fake.send(:store, entry.merge("version" => entry["version"] + 1))
      original.call(params, input, claims)
    end
    resume_worker!

    expect { check.resumed }.to raise_error(described_class::Failed, /the commit sent again changed entry \d+ on Timekeeping/)
  end

  it "fails when the owner refuses no save behind an unresolved operation" do
    allow(fake).to receive(:settle_earlier)

    expect { paused }.to raise_error(described_class::Failed, /behind the unresolved operation went through/)
  end

  it "fails the resumed step when the paused step never ran" do
    @working = true

    expect { check.resumed }.to raise_error(described_class::Failed, /no paused step for run #{run_name}/)
  end

  it "needs two businesses, one to name the other's entry" do
    expect { check(tenants: tenants.first(1)).paused }.to raise_error(described_class::Failed, /needs two businesses/)
    expect(fake.calls).to be_empty
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses before any call" do
      expect { paused }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      expect(fake.calls).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number or a path" do
    expect { described_class.new(client: nil, password:, run: "../a") }
      .to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
