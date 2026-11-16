# frozen_string_literal: true

require "rails_helper"

# The relay-paused proof (Timekeeping::RelayPausedCheck; docs/architecture/
# timekeeping-soa.md §13 item 5, §12.4), run in process through the real
# controllers on two tenants while Timekeeping owns the entries. Timekeeping
# is its consumer-side fakes (FakeTimekeeping for the entry and reservation
# APIs), the invoice operation worker runs after every request, and the relay
# delivers what the fake holds after every request only while `relaying` is
# on, as timekeeping-relay does once it is started again. These examples pin
# the two halves' writes and checks, and that each check fails the run when
# what it checks does not hold. Against the two running applications it runs
# as bin/timekeeping-demo relay-paused.
RSpec.describe Timekeeping::RelayPausedCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Relay paused business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:relay) { TimekeepingContracts::FakeRelay.new }
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
      run_workers
      answer
    end
  end

  # Each half signs in afresh, as each runs in its own process.
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
    @relaying = false
  end

  after { expect(fake.violations).to be_empty }

  # What the demo's workers do between requests: the invoice operation worker
  # delivers commit and abort, and Timekeeping's relay, while it runs, every
  # entry snapshot into the projection.
  def run_workers
    Timekeeping::InvoiceOperationWorker.new.run
    deliver if @relaying
  end

  def deliver
    return if fake.entries.empty?

    relay.deliver(Rails.application, fake.entries.map do |entry|
      relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                     **entry.except("id", "company_id", "version").symbolize_keys)
    end)
  end

  def resume_relay!
    @relaying = true
    deliver
  end

  def entry_of(tenant) = fake.entries.find { |held| held["company_id"] == tenant.company.id }

  def draft_of(tenant) = Invoice.with_discarded.where(company: tenant.company).sole

  it "with the relay paused, lists and invoices a new entry at once on both tenants, before the projection holds it" do
    check.paused

    [tenant_a, tenant_b].each do |tenant|
      entry = entry_of(tenant)
      expect(entry).to include("note" => "Relay paused #{run_name}", "duration" => 45.0, "user_id" => tenant.employee.id)
      expect(TimesheetEntry.unscoped.exists?(entry["id"])).to be(false)

      draft = draft_of(tenant)
      expect(draft).to have_attributes(status: "draft", invoice_number: "RLP-#{tenant.company.id}-#{run_name}")
      expect(draft).not_to be_discarded
      expect(draft.invoice_line_items.sole).to have_attributes(timesheet_entry_id: entry["id"], quantity: 45)
      expect(fake.holding(entry["id"])).to have_attributes(invoice_id: draft.id)
    end
    expect(fake.calls.map(&:operation).map(&:to_s).uniq).to include("create_entry", "list_entries", "candidates", "prepare", "commit")
    expect(log.string).to include("with the relay paused, a new entry was listed and invoiced at once on 2 businesses, at generation 1")
  end

  it "once the relay resumes, sees the projection catch up, then releases and discards what the run wrote" do
    check.paused
    resume_relay!
    check.resumed

    [tenant_a, tenant_b].each do |tenant|
      entry = entry_of(tenant)
      expect(entry).to include("discarded_at" => be_present)
      expect(fake.holding(entry["id"])).to be_nil
      expect(TimesheetEntry.unscoped.find(entry["id"])).to have_attributes(note: "Relay paused #{run_name}", discarded_at: be_present)
      # A discarded invoice's number becomes ARC-… (K2).
      expect(draft_of(tenant)).to be_discarded
      expect(draft_of(tenant).invoice_number).to eq("ARC-#{draft_of(tenant).id}-RLP-#{tenant.company.id}-#{run_name}")
    end
    expect(log.string).to include("once the relay resumed, the projection caught up on 2 businesses, at generation 1")
  end

  context "when the relay is not paused" do
    before { @relaying = true }

    it "fails, since an entry the projection already holds proves nothing" do
      expect { check.paused }.to raise_error(described_class::Failed, /the projection already holds entry \d+, so the relay is not paused/)
      expect(Invoice.where(company: tenant_a.company)).to be_empty
    end
  end

  it "fails the resumed half when the relay stays stopped" do
    check.paused

    expect { check.resumed }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the time-entries report shows entry \d+ as written/)
    expect(draft_of(tenant_a)).not_to be_discarded
  end

  it "fails the resumed half when the paused half did not run under that name" do
    check.paused
    resume_relay!

    expect { check(run: "another-run").resumed }.to raise_error(described_class::Failed, /holds 0 entries noted "Relay paused another-run", not one/)
  end

  it "fails when Timekeeping refuses the prepare, so the entry cannot be invoiced" do
    fake.fail_next(:prepare, status: 403, slug: "forbidden", retryable: false)

    expect { check.paused }.to raise_error(described_class::Failed, /could not save the draft RLP-#{tenant_a.company.id}-#{run_name}: 4\d\d/)
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses each half before any call" do
      expect { check.paused }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      expect { check.resumed }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries/)
      expect(fake.calls).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.paused }.to raise_error(described_class::Failed, /admission open/)
      expect(fake.calls).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
