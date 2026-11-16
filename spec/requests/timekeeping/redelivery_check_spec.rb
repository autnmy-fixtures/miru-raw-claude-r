# frozen_string_literal: true

require "rails_helper"

# The duplicate-and-reordered-delivery proof (Timekeeping::RedeliveryCheck;
# docs/architecture/timekeeping-soa.md §13 item 6, §5.4), run in process
# through the real controllers on two tenants while Timekeeping owns the
# entries. Timekeeping is its consumer-side fakes (FakeTimekeeping for the
# entry and reservation APIs), and the invoice operation worker runs after
# every request. The relay is FakeRelay over the projection endpoint: every
# entry version the fake holds is one snapshot of an outbox, delivered after
# every request while the relay runs and held while it is stopped. The
# resend is OutboxRedelivery's order, sent as Timekeeping sends it on the
# demo: each entry's newest, then each older one alone, newest first, then
# all of them again. These examples pin the four steps' writes and checks,
# and that each check fails the run when what it checks does not hold.
# Against the two running applications it runs as bin/timekeeping-demo
# redelivery.
RSpec.describe Timekeeping::RedeliveryCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Redelivery business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T120000Z-rd56" }

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
    @relay_running = true
    # The outbox: one snapshot per entry version, in the order written, and
    # how many of them the relay has delivered.
    @outbox = []
    @delivered = 0
  end

  after { expect(fake.violations).to be_empty }

  # What the demo's workers do between requests: the invoice operation worker
  # delivers commit and abort, every new entry version goes into the outbox,
  # and the relay delivers what it holds while it runs.
  def run_workers
    Timekeeping::InvoiceOperationWorker.new.run
    record
    deliver if @relay_running
  end

  def record
    fake.entries.each do |entry|
      next if @outbox.any? { |held| held["entry_id"] == entry["id"] && held["version"] == entry["version"] }

      @outbox << relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                                **entry.except("id", "company_id", "version").symbolize_keys)
    end
  end

  def deliver
    pending = @outbox.drop(@delivered)
    return if pending.empty?

    relay.deliver(Rails.application, pending)
    @delivered = @outbox.size
  end

  def stop_relay! = @relay_running = false

  def start_relay!
    @relay_running = true
    deliver
  end

  # OutboxRedelivery's batches for these entries, each with its receipt.
  def redeliver!(ids)
    histories = ids.map { |id| @outbox.select { |snapshot| snapshot["entry_id"] == id } }
    batches = [histories.map(&:last)] + histories.flat_map { |all| all[0...-1].reverse.map { |snapshot| [snapshot] } } +
      [@outbox.select { |snapshot| ids.include?(snapshot["entry_id"]) }]
    batches.map { |batch| relay.deliver(Rails.application, batch).values_at("applied", "ignored") }
  end

  # A write as a faulty projection consumer would make it, so the runtime
  # single-writer guard knows it from any other writer.
  def as_consumer(&) = Timekeeping::SingleWriterWatch.projection(&)

  def entries_of(tenant) = fake.entries.select { |held| held["company_id"] == tenant.company.id }.sort_by { |entry| entry["id"] }

  def draft_of(tenant) = Invoice.with_discarded.where(company: tenant.company).sole

  def projected(entry) = TimesheetEntry.unscoped.find(entry["id"])

  def run_to_held
    check.projected
    stop_relay!
    check.held
  end

  it "with the relay running, projects a new entry X on both tenants" do
    check.projected

    [tenant_a, tenant_b].each do |tenant|
      x = entries_of(tenant).sole
      expect(x).to include("note" => "Redelivery #{run_name} X", "duration" => 20.0, "version" => 1)
      expect(projected(x)).to have_attributes(note: x["note"], version: 1)
    end
    expect(log.string).to include("entry X is projected as Timekeeping holds it on 2 businesses")
  end

  it "with the relay stopped, edits and reserves X and Y while the projection stays behind, and names them" do
    ids = run_to_held

    expect(ids).to eq([tenant_a, tenant_b].flat_map { |tenant| entries_of(tenant).map { |entry| entry["id"] } })
    [tenant_a, tenant_b].each do |tenant|
      x, y = entries_of(tenant)
      expect(x).to include("note" => "Redelivery #{run_name} X, edited again", "duration" => 35.0, "version" => 3)
      expect(y).to include("note" => "Redelivery #{run_name} Y, edited", "duration" => 55.0, "version" => 2)
      expect(projected(x)).to have_attributes(note: "Redelivery #{run_name} X", duration: 20.0, version: 1)
      expect(TimesheetEntry.unscoped.exists?(y["id"])).to be(false)

      draft = draft_of(tenant)
      expect(draft).to have_attributes(status: "draft", invoice_number: "RDL-#{tenant.company.id}-#{run_name}")
      expect(draft.invoice_line_items.map { |line| [line.timesheet_entry_id, line.quantity] }).to contain_exactly([x["id"], 35], [y["id"], 55])
      expect([x, y].map { |entry| fake.holding(entry["id"])&.invoice_id }).to eq([draft.id, draft.id])
      expect(Timekeeping::InvoiceOperation.where(invoice_id: draft.id)).to all(have_attributes(state: "succeeded", delivered_at: be_present))
    end
    expect(log.string).to include("redelivery: entries: #{ids.join(' ')}")
  end

  it "after the out-of-order resend, with the relay still stopped, sees the projection at Timekeeping's versions" do
    ids = run_to_held

    receipts = redeliver!(ids)
    # 4 newest applied; X's 2 and Y's 1 older ones per tenant, each ignored;
    # then all 10 again, all ignored.
    expect(receipts).to eq([[4, 0]] + Array.new(6, [0, 1]) + [[0, 10]])
    check.reordered

    [tenant_a, tenant_b].each do |tenant|
      entries_of(tenant).each do |entry|
        expect(projected(entry)).to have_attributes(note: entry["note"], version: entry["version"], duration: entry["duration"])
      end
    end
    expect(log.string).to include(
      "with the relay stopped, the out-of-order resend left the projection at Timekeeping's versions on 2 businesses, at generation 1"
    )
  end

  it "after the relay delivers every snapshot again, sees nothing changed, then releases and discards what the run wrote" do
    ids = run_to_held
    redeliver!(ids)
    check.reordered
    start_relay!
    check.duplicated

    [tenant_a, tenant_b].each do |tenant|
      entries_of(tenant).each do |entry|
        expect(entry).to include("discarded_at" => be_present)
        expect(fake.holding(entry["id"])).to be_nil
        expect(projected(entry)).to have_attributes(version: entry["version"], discarded_at: be_present)
      end
      # A discarded invoice's number becomes ARC-… (K2).
      expect(draft_of(tenant)).to be_discarded
    end
    expect(log.string).to include("the relay's second delivery of every snapshot changed nothing on 2 businesses, at generation 1")
  end

  it "fails the held step when the relay keeps running, since a projection that follows proves nothing" do
    check.projected

    expect { check.held }.to raise_error(described_class::Failed, /the projection moved entry \d+ from .* so the relay is not stopped/)
  end

  it "fails the reordered step when nothing was resent" do
    run_to_held

    expect { check.reordered }.to raise_error(described_class::Failed, /the projection holds entry \d+ as .*not as Timekeeping does .*run timekeeping:redeliver/)
  end

  it "fails the reordered step when an older snapshot is applied after the newest" do
    ids = run_to_held
    redeliver!(ids)
    x = entries_of(tenant_a).first
    # What a consumer that applies whatever it is sent would leave.
    as_consumer { TimesheetEntry.unscoped.where(id: x["id"]).update_all(version: 2, note: "Redelivery #{run_name} X, edited") }

    expect { check.reordered }.to raise_error(described_class::Failed, /#{tenant_a.company.name}: the projection holds entry #{x['id']} as .*"version" => 2/)
  end

  it "fails the duplicated step when the projection moved off Timekeeping's version" do
    ids = run_to_held
    redeliver!(ids)
    check.reordered
    start_relay!
    y = entries_of(tenant_b).last
    as_consumer { TimesheetEntry.unscoped.where(id: y["id"]).update_all(version: 1, duration: 40.0) }

    expect { check.duplicated }.to raise_error(described_class::Failed, /after the relay's second delivery the projection holds entry #{y['id']}/)
  end

  it "fails the held step when the projected step did not run under that name" do
    check.projected
    stop_relay!

    expect { check(run: "another-run").held }.to raise_error(described_class::Failed, /holds 0 entries noted "Redelivery another-run X", not one/)
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses each step before any call" do
      %i[projected held reordered duplicated].each do |step|
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
