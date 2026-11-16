# frozen_string_literal: true

require "rails_helper"

# The stale-generation part of the failure injection (Timekeeping::
# StaleGenerationCheck; docs/architecture/timekeeping-soa.md §12.4, §9.3, §13
# item 6), run in process through the real controllers, write gateway and
# invoice writes on two tenants while Timekeeping owns the entries.
# Timekeeping is its consumer-side fake (FakeTimekeeping), which refuses any
# mutating call that does not carry its generation before it reads a
# receipt, as Timekeeping's own admission does. The invoice operation worker
# runs after every request, as miru-jobs does. Timekeeping's own alert, a log
# line tagged with the request id, is found in timekeeping-web's log by
# bin/timekeeping-demo stale-generation; here the fake's calls show the
# request id each refused call carried.
RSpec.describe Timekeeping::StaleGenerationCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Stale generation business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T210000Z-5e6f" }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      Timekeeping::InvoiceOperationWorker.new.run
      answer
    end
  end

  def check(run: run_name)
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run:,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:)
    )
  end

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  before do
    tenants
    set_timekeeping_ownership!(ownership)
  end

  after { expect(fake.violations).to be_empty }

  def entries_of(tenant)
    fake.entries.select { |held| held["company_id"] == tenant.company.id }
  end

  def refused_ids = log.string[/stale generation: refused request ids: (.*)$/, 1].to_s.split

  it "refuses every call carrying another generation, changes nothing, and sends the retries under the current one, on both tenants" do
    expect { check.call }.not_to raise_error

    [tenant_a, tenant_b].each do |tenant|
      held = entries_of(tenant)
      aggregate_failures do
        # One X and one Y were ever created: no refused create wrote one.
        expect(held.pluck("note")).to contain_exactly(
          "Stale generation #{run_name} X edited", "Stale generation #{run_name} Y"
        )
        expect(held).to all(include("discarded_at" => be_present))
        expect(held.map { |entry| fake.holding(entry.fetch("id")) }).to all(be_nil)

        draft = Invoice.with_discarded.where(company: tenant.company).where("invoice_number LIKE ?", "%STG-#{tenant.company.id}-#{run_name}").sole
        expect(draft).to be_discarded
        expect(Timekeeping::InvoiceOperation.where(invoice_id: draft.id).order(:id).pluck(:kind, :state, :generation))
          .to eq([["save", "succeeded", 1], ["save", "succeeded", 1], ["discard", "succeeded", 1]])
        # The prepare carrying generation 0 never reached a handler, so the
        # fake registered only the ledger's three operations.
        expect(fake.calls.count { |call| call.operation == :prepare && call.params["invoice_id"] == draft.id.to_s }).to eq(3)
      end
    end

    # Seven refused calls on each business, each under a request id of its own.
    ids = refused_ids
    expect(ids.size).to eq(14)
    expect(ids.uniq).to eq(ids)
    expect(ids).to all(match(/\A#{run_name}-\d+-\d+\z/))
    expect(Timekeeping::InvoiceOperation.state_pending).to be_empty
    expect(Timekeeping::InvoiceOperation.undelivered).to be_empty
    expect(log.string).to include(
      "creates of entry X carrying generations 0 and 2, and the gateway's send under 0, were refused and wrote nothing",
      "its retry carrying generation 0 was refused, and its retry under 1 was answered the stored result, so it ran once",
      "each carrying generation 0, were refused; the commit under 1 was answered its stored receipt, and nothing changed",
      "the admin retried the save adding entry",
      "on 2 businesses, at generation 1"
    )
  end

  it "names, for every refused call, the request id the call carried to Timekeeping" do
    sent = []
    allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_wrap_original do |original, method, url, body, headers, &block|
      sent << headers["X-Request-Id"] if headers&.key?("X-Ownership-Generation") && headers["X-Ownership-Generation"] != fake.generation.to_s
      original.call(method, url, body, headers, &block)
    end

    check.call

    expect(sent).to match_array(refused_ids)
  end

  it "fails when the owner admits a call carrying another generation" do
    allow(fake).to receive(:check_generation)

    expect { check.call }.to raise_error(described_class::Failed, /the create of entry X carrying generation 0 answered success, not 409 stale-generation/)
  end

  it "fails when this application reports no alert for a refusal" do
    allow(Timekeeping::Signals).to receive(:stale_generation_refused) { |problem, **| problem }

    expect { check.call }.to raise_error(described_class::Failed, /carrying generation 0 reported 0 stale-generation alerts here, not 1/)
  end

  it "fails when the owner runs an admitted command again instead of answering its stored result" do
    allow(fake).to receive(:replayable) { |*, &change| change.call }

    expect { check.call }.to raise_error(described_class::Failed, /the retry of the update of entry \d+ under generation 1 answered .*not its stored result/)
  end

  context "when Timekeeping owns the entries again after a re-cutover" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("re-cut over to Timekeeping") }

    it "sends the generation before the current one and the one after it" do
      check.call

      expect(log.string).to include("creates of entry X carrying generations 2 and 4", "at generation 3")
    end
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses before any call" do
      expect { check.call }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      expect(fake.calls).to be_empty
    end
  end

  context "when the prepared application owns the entries, after a rollback" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application") }

    it "refuses before any call, as no call goes to Timekeeping under a generation then" do
      expect { check.call }.to raise_error(described_class::Failed, /owner monolith/)
      expect(fake.calls).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.call }.to raise_error(described_class::Failed, /admission open/)
      expect(fake.calls).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number or a request id" do
    expect { described_class.new(client: nil, password:, run: "a b;c") }
      .to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
