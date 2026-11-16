# frozen_string_literal: true

require "rails_helper"

# The live contract check of the independent-deployment proof
# (Timekeeping::ContractCheck; docs/architecture/timekeeping-soa.md §13 item
# 4), run in process through the real controllers on two tenants while
# Timekeeping owns the entries. Timekeeping is its consumer-side fakes
# (FakeTimekeeping for the entry and reservation APIs, FakeHandoff for the
# handoff API), the invoice operation worker runs and the relay delivers what
# the fake holds after every request, as the demo's workers would. These
# examples pin the check's sequence of writes and checks, and that each check
# fails the run when what it checks does not hold. Against the two running
# applications it runs as bin/timekeeping-demo contract-check.
RSpec.describe Timekeeping::ContractCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Contract check business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("re-cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  # Timekeeping's copy of the ownership record, as the handoff left it.
  let(:timekeeping_copy) { ownership }
  let!(:fake_handoff) { TimekeepingContracts::FakeHandoff.new(**timekeeping_copy).install! }
  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:relaying) { true }
  let(:log) { StringIO.new }

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

  let(:check) do
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:,
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

  after do
    expect(fake.violations).to be_empty
    expect(fake_handoff.violations).to be_empty
  end

  # What the demo's workers do between requests: the invoice operation worker
  # delivers commit and abort, and Timekeeping's relay delivers every entry
  # snapshot into the projection.
  def run_workers
    Timekeeping::InvoiceOperationWorker.new.run
    return unless relaying && fake.entries.any?

    relay.deliver(Rails.application, fake.entries.map do |entry|
      relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                     **entry.except("id", "company_id", "version").symbolize_keys)
    end)
  end

  def operations_called = fake.calls.map(&:operation).map(&:to_s).uniq

  it "drives every contract on both tenants and leaves nothing reserved" do
    check.call

    expect(fake_handoff.calls.map(&:operation)).to eq([:read_handoff])
    expect(operations_called).to include(
      "create_entry", "update_entry", "list_entries", "candidates", "prepare", "commit", "discard_entry"
    )
    [tenant_a, tenant_b].each do |tenant|
      entry = fake.entries.find { |held| held["company_id"] == tenant.company.id }
      expect(entry).to include("note" => a_string_ending_with("edited"), "duration" => 43.25, "discarded_at" => be_present)
      expect(fake.holding(entry["id"])).to be_nil
      expect(TimesheetEntry.find(entry["id"])).to have_attributes(user_id: tenant.employee.id, discarded_at: be_present)

      draft = Invoice.where(company: tenant.company).sole
      # A discarded invoice's number becomes ARC-… (K2).
      expect(draft).to have_attributes(status: "draft", invoice_number: a_string_matching(/\AARC-\d+-CHK-#{tenant.company.id}-\h{6}\z/))
      expect(draft).to be_discarded
    end
    expect(log.string).to include("every contract held between the two running applications, on 2 businesses, at generation 3")
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses before any call, since no contract crosses between the applications" do
      expect { check.call }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
      expect(fake.calls).to be_empty
      expect(fake_handoff.calls).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.call }.to raise_error(described_class::Failed, /admission open/)
      expect(fake.calls).to be_empty
    end
  end

  context "when Timekeeping's copy of the ownership record disagrees" do
    let(:timekeeping_copy) { ownership.merge(generation: 2) }

    it "fails before any write" do
      expect { check.call }.to raise_error(described_class::Failed, /Timekeeping's copy of the ownership record is .*generation: 2/)
      expect(fake.calls).to be_empty
    end
  end

  context "when the relay delivers nothing" do
    let(:relaying) { false }

    it "fails waiting for the time-entries report, which reads the projection" do
      expect { check.call }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the time-entries report shows entry \d+/)
    end
  end

  it "fails when Timekeeping refuses a write" do
    fake.fail_next(:create_entry, status: 403, slug: "forbidden", retryable: false)

    expect { check.call }.to raise_error(described_class::Failed, /could not create an entry for Contract check business 1: 403/)
  end
end
