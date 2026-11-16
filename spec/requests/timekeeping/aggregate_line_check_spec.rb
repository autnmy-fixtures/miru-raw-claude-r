# frozen_string_literal: true

require "rails_helper"

# The aggregate-line proof (Timekeeping::AggregateLineCheck; docs/
# architecture/timekeeping-soa.md §12.4, F3), run in process through the real
# controllers on two tenants while Timekeeping owns the entries. Timekeeping
# is its consumer-side fake (FakeTimekeeping, for the entry and reservation
# APIs), and the invoice operation worker runs after every request while
# `working` is on, as miru-jobs does. Timekeeping is stopped by refusing every
# connection to it, as a stopped timekeeping-web does. These examples pin the
# three steps' writes and checks, and that each check fails the run when what
# it checks does not hold. Against the two running applications it runs as
# bin/timekeeping-demo aggregate-line.
RSpec.describe Timekeeping::AggregateLineCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Aggregate line business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T120000Z-ab12" }

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

  # Each step signs in afresh, as each runs in its own process.
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
    @working = true
  end

  after { expect(fake.violations).to be_empty }

  # A stopped timekeeping-web: every connection to it is refused. The stub
  # declared last is the one WebMock answers with.
  def stop_timekeeping!
    @outage = WebMock::API.stub_request(:any, TimekeepingContracts::FakeTimekeeping::SERVED).to_raise(Errno::ECONNREFUSED)
  end

  def start_timekeeping!
    WebMock::API.remove_request_stub(@outage)
  end

  def entries_of(tenant)
    fake.entries.select { |held| held["company_id"] == tenant.company.id }.index_by { |held| held["note"].split.last }
  end

  def draft_of(tenant) = Invoice.with_discarded.find_by(company: tenant.company, invoice_number: "AGL-#{tenant.company.id}-#{run_name}")

  def other_of(tenant) = Invoice.with_discarded.where(company: tenant.company).where("invoice_number LIKE ?", "%AGL-#{tenant.company.id}-#{run_name}-W").sole

  def operations(invoice) = Timekeeping::InvoiceOperation.where(invoice_id: invoice.id).order(:created_at, :id)

  it "keeps the entry the direct line references when the grouped line goes, and releases the other, on both tenants" do
    check.held

    [tenant_a, tenant_b].each do |tenant|
      entries = entries_of(tenant)
      x, y, w = entries.values_at("X", "Y", "W").map { |entry| entry.fetch("id") }
      expect(entries.transform_values { |entry| entry["duration"] }).to eq("X" => 30.0, "Y" => 50.0, "W" => 20.0)

      draft = draft_of(tenant)
      expect(draft).to have_attributes(status: "draft", discarded_at: nil)
      expect(draft.invoice_line_items.where.not(timesheet_entry_id: nil).sole.timesheet_entry_id).to eq(x)
      expect(draft.invoice_line_items.find_by!(timesheet_entry_id: nil).linked_timesheet_entry_ids).to contain_exactly(x, y)
      expect([x, y].map { |id| fake.holding(id) }).to all(have_attributes(invoice_id: draft.id, state: :committed))
      expect(fake.holding(w)).to have_attributes(invoice_id: other_of(tenant).id, state: :committed)

      # The first save, the refused one (F1), the two removals, both lines back.
      expect(operations(draft).map { |intent| [intent.kind, intent.state, intent.entry_ids.sort] }).to eq([
        ["save", "succeeded", [x, y].sort], ["save", "failed", [x, w].sort], ["save", "succeeded", [x]],
        ["save", "succeeded", []], ["save", "succeeded", [x, y].sort]
      ])
    end
    expect(log.string).to include(
      "was refused (F1), and changed nothing",
      "removing the grouped line kept entry",
      "removing the remaining direct line released entry",
      "removing a draft's grouped line kept the entry its direct line references and released the other, on 2 businesses, " \
      "at generation 1"
    )
  end

  it "with Timekeeping stopped, fails a save and a destroy of the draft and keeps it, then releases its whole set once it is back" do
    check.held
    stop_timekeeping!
    check.outage

    [tenant_a, tenant_b].each do |tenant|
      draft = draft_of(tenant)
      expect(draft.invoice_line_items.count).to eq(2)
      expect(operations(draft).last(2).map { |intent| [intent.kind, intent.state, intent.delivered_at] })
        .to eq([["save", "failed", nil], ["destroy", "failed", nil]])
    end
    expect(log.string).to include("with Timekeeping stopped, a save and a destroy of the draft failed and left both its lines, on 2 businesses")

    start_timekeeping!
    check.restored

    [tenant_a, tenant_b].each do |tenant|
      entries = entries_of(tenant)
      expect(entries.values).to all(include("discarded_at" => be_present))
      expect(entries.values.map { |entry| fake.holding(entry.fetch("id")) }).to all(be_nil)
      expect(draft_of(tenant)).to be_nil
      # A discarded invoice's number becomes ARC-… (K2).
      expect(other_of(tenant)).to be_discarded
    end
    expect(Timekeeping::InvoiceOperation.undelivered).to be_empty
    expect(log.string).to include(
      "stayed reserved through the failures, and both aborts were delivered",
      "released entries",
      "every reservation outlived the failed save and destroy, and destroying the draft released its whole set, on 2 businesses"
    )
  end

  it "fails the outage step before any write when Timekeeping still answers" do
    check.held

    expect { check.outage }.to raise_error(described_class::Failed, /the invoice candidates answered 200 while Timekeeping should be stopped/)
    expect(draft_of(tenant_a).invoice_line_items.count).to eq(2)
    expect(operations(draft_of(tenant_a)).last.state).to eq("succeeded")
  end

  it "fails the restored step while Timekeeping stays stopped" do
    check.held
    stop_timekeeping!
    check.outage

    expect { check.restored }.to raise_error(described_class::Failed, /could not read the invoice candidates: 503/)
    expect(draft_of(tenant_a)).to be_present
  end

  it "fails when a removal's release is never delivered, since the entry would stay reserved" do
    @working = false

    expect { check.held }.to raise_error(
      described_class::Failed,
      /timed out after 2 s waiting until after removing the grouped line of draft \d+, the candidates leave out entries \[\d+, \d+\] and offer \[\d+\]/
    )
  end

  it "fails the restored step while the failed operations' aborts stay undelivered" do
    check.held
    stop_timekeeping!
    check.outage
    start_timekeeping!
    @working = false

    expect { check.restored }.to raise_error(described_class::Failed, /waiting until the invoice operation worker delivers the aborts/)
  end

  it "fails when destroying the draft does not release its entries" do
    check.held
    stop_timekeeping!
    check.outage
    start_timekeeping!
    Timekeeping::InvoiceOperationWorker.new.run
    # The destroy's commit, which releases the set, is never delivered.
    @working = false

    expect { check.restored }.to raise_error(
      described_class::Failed, /after destroying draft \d+, the candidates leave out entries \[\d+\] and offer \[\d+, \d+\]/
    )
  end

  it "fails a step that does not follow the held step of its run" do
    expect { check.restored }.to raise_error(described_class::Failed, /no kept draft AGL-\d+-#{run_name}; run the held step first/)

    check.held
    stop_timekeeping!

    expect { check(run: "another-run").outage }.to raise_error(described_class::Failed, /no kept draft AGL-\d+-another-run/)
  end

  it "fails a second held step under the same name, as its draft number is taken" do
    check.held

    expect { check.held }.to raise_error(described_class::Failed, /could not save the draft AGL-\d+-#{run_name}: 422/)
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses each step before any call" do
      %i[held outage restored].each do |step|
        expect { check.public_send(step) }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      end
      expect(fake.calls).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.held }.to raise_error(described_class::Failed, /admission open/)
      expect(fake.calls).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
