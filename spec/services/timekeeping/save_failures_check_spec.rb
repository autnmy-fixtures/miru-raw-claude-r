# frozen_string_literal: true

require "rails_helper"

# The save-failure part of the failure injection (Timekeeping::
# SaveFailuresCheck; docs/architecture/timekeeping-soa.md §12.4, §9.3), run in
# process through the real controllers and invoice writes on two tenants while
# Timekeeping owns the entries. Timekeeping is its consumer-side fake
# (FakeTimekeeping, for the entry and reservation APIs), and the invoice
# operation worker runs after every request while `working` is on, as
# miru-jobs does, with recovery looking at once, as the demo's worker does
# once the save's 30 s time limit has passed. The crash runs in this process:
# it raises an exception no rescue of the save catches, which ends the invoice
# transaction without commit and records nothing, as a killed process does.
# Against the two running applications the crash is a forked child killed
# with SIGKILL, and it runs as bin/timekeeping-demo save-failures.
RSpec.describe Timekeeping::SaveFailuresCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  # What a killed process leaves: neither the save's rescue nor its
  # transaction's commit runs.
  let(:killed) { Class.new(Exception) }

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Save failures business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T130000Z-cd34" }
  let(:crashes) { [] }
  let(:crash) do
    lambda do |&save|
      crashes << :crashed
      save.call(-> { raise killed })
    rescue killed
      nil
    end
  end

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      Timekeeping::InvoiceOperationWorker.new(time_limit: 0.seconds).run if @working
      answer
    end
  end

  def check(crash: self.crash)
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run: run_name,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:, crash:)
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
    # The boundary's jitter between prepare attempts.
    allow_any_instance_of(Timekeeping::InvoiceBoundary).to receive(:sleep)
  end

  after { expect(fake.violations).to be_empty }

  def entries_of(tenant)
    fake.entries.select { |held| held["company_id"] == tenant.company.id }.index_by { |held| held["note"].split.last }
  end

  def save_of(tenant, letter)
    id = entries_of(tenant).fetch(letter).fetch("id")
    Timekeeping::InvoiceOperation.where(company_id: tenant.company.id).where("? = ANY(entry_ids)", id).sole
  end

  def prepares_of(intent)
    fake.calls.count { |call| call.operation == :prepare && call.params["operation_id"] == intent.operation_id }
  end

  it "ends every failed save failed and aborted, and every replay as its operation stands, on both tenants" do
    check.call

    expect(crashes).to eq(%i[crashed crashed])
    [tenant_a, tenant_b].each do |tenant|
      entries = entries_of(tenant)
      expect(entries.transform_values { |entry| entry["duration"] }).to eq("A" => 15.0, "B" => 25.0, "C" => 35.0, "D" => 45.0)
      expect(entries.values).to all(include("discarded_at" => be_present))
      expect(entries.values.map { |entry| fake.holding(entry.fetch("id")) }).to all(be_nil)

      # A's draft committed, and is discarded at the end; its operation still
      # reads committed after both replays.
      # A discarded invoice's number becomes ARC-… (K2).
      draft = Invoice.with_discarded.where(company: tenant.company).where("invoice_number LIKE ?", "%SVF-#{tenant.company.id}-#{run_name}").sole
      expect(draft).to be_discarded
      expect(save_of(tenant, "A")).to have_attributes(state: "succeeded", delivered_at: be_present)
      # B rolled back, C's answers were lost, D crashed: each failed, aborted,
      # and wrote no invoice.
      %w[B C D].each do |letter|
        intent = save_of(tenant, letter)
        expect(intent).to have_attributes(state: "failed", delivered_at: be_present)
        expect(Invoice.with_discarded.exists?(intent.invoice_id)).to be(false)
      end
      expect(prepares_of(save_of(tenant, "C"))).to eq(3)
      # The first prepare, the committed replay and the forced-pending one.
      expect(prepares_of(save_of(tenant, "A"))).to eq(3)
      expect(prepares_of(save_of(tenant, "B"))).to eq(2)
    end
    expect(Timekeeping::InvoiceOperation.state_pending).to be_empty
    expect(Timekeeping::InvoiceOperation.undelivered).to be_empty
    expect(log.string).to include(
      "was answered its receipt and returned the existing outcome",
      "forced pending while committed at its owner, failed with a retryable reconciliation error and changed nothing",
      "a save that rolled back after its prepare recorded operation",
      "failed and changed nothing",
      "3 times and every answer was lost; the save failed as retryable",
      "is still pending, there is no invoice",
      "recovery recorded operation",
      "on 2 businesses, at generation 1"
    )
  end

  it "fails when the crash does not happen, as the save then commits" do
    expect { check(crash: ->(&save) { save.call(-> { }) }).call }.to raise_error(
      described_class::Failed, /after the crash, operation \S+ is succeeded, not pending/
    )
  end

  it "fails when the invoice operation worker never delivers, before any replay" do
    @working = false

    expect { check.call }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the invoice operation worker delivers operation/)
    expect(fake.calls.count { |call| call.operation == :prepare }).to eq(1)
  end

  it "fails when the owner keeps no terminal receipt, so a replay of a committed operation runs the change again" do
    allow(fake).to receive(:terminal_receipt).and_return(nil)

    expect { check.call }.to raise_error(described_class::Failed, /the replay of operation \S+ ran the invoice change again/)
    expect(Timekeeping::InvoiceOperation.state_succeeded.count).to eq(1)
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses before any call" do
      expect { check.call }.to raise_error(described_class::Failed, /runs while Timekeeping owns the entries .*owner legacy/)
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

  it "refuses a run name that could not be part of an invoice number" do
    expect { described_class.new(client: nil, password:, run: "a b;c") }
      .to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end

  describe Timekeeping::SaveFailuresCheck::ForkedCrash do
    it "answers once the child that ran the save is killed by SIGKILL" do
      expect { described_class.new.call { |kill| kill.call } }.not_to raise_error
    end

    it "fails when the child's save ends without crashing" do
      expect { described_class.new.call { |_kill| nil } }
        .to raise_error(Timekeeping::SaveFailuresCheck::Failed, /ended with .*exit 3.*not killed by SIGKILL/)
        .and output(/the save ended without crashing/).to_stderr_from_any_process
    end
  end
end
