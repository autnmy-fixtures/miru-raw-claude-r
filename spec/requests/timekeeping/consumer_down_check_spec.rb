# frozen_string_literal: true

require "rails_helper"

# The projection-consumer-down proof (Timekeeping::ConsumerDownCheck;
# docs/architecture/timekeeping-soa.md §9.3, §12.4), run in process through
# the real controllers on two tenants while Timekeeping owns the entries.
# Timekeeping is its consumer-side fakes (FakeTimekeeping for the entry and
# reservation APIs), the invoice operation worker runs after every request,
# and the relay delivers what the fake holds after every request. While the
# consumer is down, each delivery is sent and refused, so it lands nowhere,
# as timekeeping-relay's are refused at connect on the demo. These examples
# pin the three steps' writes and checks, and that each check fails the run
# when what it checks does not hold. Against the two running applications it
# runs as bin/timekeeping-demo consumer-down.
RSpec.describe Timekeeping::ConsumerDownCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Consumer down business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T120000Z-cd34" }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      run_workers
      answer
    end
  end

  # Each step signs in afresh, as each runs in its own process.
  def check(run: run_name)
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run:,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, settle: 0, tenants:)
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
    @consumer_up = true
    @refused = 0
  end

  after { expect(fake.violations).to be_empty }

  # What the demo's workers do between requests: the invoice operation worker
  # delivers commit and abort, and Timekeeping's relay sends every entry
  # snapshot to the projection consumer, which applies them only while it
  # is up.
  def run_workers
    Timekeeping::InvoiceOperationWorker.new.run
    deliver
  end

  def deliver
    return if fake.entries.empty?
    return @refused += 1 unless @consumer_up

    relay.deliver(Rails.application, fake.entries.map do |entry|
      relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                     **entry.except("id", "company_id", "version").symbolize_keys)
    end)
  end

  def take_consumer_down! = @consumer_up = false

  def bring_consumer_back!
    @consumer_up = true
    deliver
  end

  def entries_of(tenant) = fake.entries.select { |held| held["company_id"] == tenant.company.id }.sort_by { |entry| entry["id"] }

  def draft_of(tenant) = Invoice.with_discarded.where(company: tenant.company).sole

  def projected(entry) = TimesheetEntry.unscoped.find(entry["id"])

  def run_to_down
    check.projected
    take_consumer_down!
    check.down
  end

  it "with the consumer up, projects a new entry X on both tenants" do
    check.projected

    [tenant_a, tenant_b].each do |tenant|
      x = entries_of(tenant).sole
      expect(x).to include("note" => "Consumer down #{run_name} X", "duration" => 30.0, "version" => 1)
      expect(projected(x)).to have_attributes(note: x["note"], version: 1)
    end
    expect(log.string).to include("entry X is projected as Timekeeping holds it on 2 businesses; the consumer is up")
  end

  it "with the consumer down, lists and invoices an edited and a new entry at once, while the projection stays as it was" do
    run_to_down

    [tenant_a, tenant_b].each do |tenant|
      x, y = entries_of(tenant)
      expect(x).to include("note" => "Consumer down #{run_name} X, edited", "duration" => 50.0, "version" => 2)
      expect(y).to include("note" => "Consumer down #{run_name} Y", "duration" => 45.0)
      expect(projected(x)).to have_attributes(note: "Consumer down #{run_name} X", duration: 30.0, version: 1)
      expect(TimesheetEntry.unscoped.exists?(y["id"])).to be(false)

      draft = draft_of(tenant)
      expect(draft).to have_attributes(status: "draft", invoice_number: "CND-#{tenant.company.id}-#{run_name}")
      expect(draft.invoice_line_items.map { |line| [line.timesheet_entry_id, line.quantity] }).to contain_exactly([x["id"], 50], [y["id"], 45])
      expect([x, y].map { |entry| fake.holding(entry["id"])&.invoice_id }).to eq([draft.id, draft.id])
    end
    expect(@refused).to be_positive
    expect(log.string).to include(
      "with the projection consumer down, an edited and a new entry were listed and invoiced at once on 2 businesses, " \
      "and the projection stayed as it was, at generation 1"
    )
  end

  it "once the consumer is back, sees the projection at Timekeeping's versions, then releases and discards what the run wrote" do
    run_to_down
    bring_consumer_back!
    check.restored

    [tenant_a, tenant_b].each do |tenant|
      x, y = entries_of(tenant)
      [x, y].each do |entry|
        expect(entry).to include("discarded_at" => be_present)
        expect(fake.holding(entry["id"])).to be_nil
        expect(projected(entry)).to have_attributes(note: entry["note"], version: entry["version"], discarded_at: be_present)
      end
      # A discarded invoice's number becomes ARC-… (K2).
      expect(draft_of(tenant)).to be_discarded
      expect(draft_of(tenant).invoice_number).to eq("ARC-#{draft_of(tenant).id}-CND-#{tenant.company.id}-#{run_name}")
    end
    expect(log.string).to include(
      "the projection caught up with entry X #{entries_of(tenant_a).first['id']} at version 2",
      "once the consumer was back, the relay's resend brought the projection to Timekeeping's versions on 2 businesses, at generation 1"
    )
  end

  context "when the consumer stays up" do
    it "fails the down step, since a projection that follows proves nothing" do
      check.projected

      expect { check.down }.to raise_error(described_class::Failed, /the projection moved entry \d+ from .* so the consumer is not down/)
      expect(Invoice.where(company: tenant_a.company)).to be_empty
    end
  end

  it "fails the projected step when the consumer is already down" do
    take_consumer_down!

    expect { check.projected }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the projection holds entry \d+ as Timekeeping does/)
  end

  it "fails the down step when the projected step did not run under that name" do
    check.projected
    take_consumer_down!

    expect { check(run: "another-run").down }.to raise_error(described_class::Failed, /holds 0 entries noted "Consumer down another-run X", not one/)
  end

  it "fails the restored step when the consumer stays down" do
    run_to_down

    expect { check.restored }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the projection holds entry \d+ as Timekeeping does/)
    expect(draft_of(tenant_a)).not_to be_discarded
  end

  it "fails when Timekeeping refuses the prepare, so the entries cannot be invoiced" do
    check.projected
    take_consumer_down!
    fake.fail_next(:prepare, status: 403, slug: "forbidden", retryable: false)

    expect { check.down }.to raise_error(described_class::Failed, /could not save the draft CND-#{tenant_a.company.id}-#{run_name}: 4\d\d/)
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses each step before any call" do
      %i[projected down restored].each do |step|
        expect { check.public_send(step) }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      end
      expect(fake.calls).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.projected }.to raise_error(described_class::Failed, /admission open/)
      expect(fake.calls).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
