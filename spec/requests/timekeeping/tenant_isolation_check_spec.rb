# frozen_string_literal: true

require "rails_helper"

# §13 item 7 (Timekeeping::TenantIsolationCheck; docs/architecture/
# timekeeping-soa.md §6.3, §2.1, §12.2), run in process through the real
# controllers, write gateway, invoice writes and projection endpoint on two
# tenants, under each owner: the legacy owner, the prepared application
# after a rollback, and Timekeeping, which is its consumer-side fake
# (FakeTimekeeping) here and keeps tenant isolation by the token's company,
# as Timekeeping does. The invoice operation worker runs after every request,
# as miru-jobs does, and so does the owner's relay into the projection: the
# prepared application's own (Timekeeping::LocalRelay), or, for the fake,
# the consumer-side fake of Timekeeping's relay (FakeRelay). Each tenant
# also starts with one projected entry of its own.
RSpec.describe Timekeeping::TenantIsolationCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let!(:projected_entries) { [tenant_a, tenant_b].map { |tenant| unbilled_entry(tenant, duration: 30.0) } }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Tenant isolation business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T220000Z-7a8b" }
  # Called with each request and its answer, after the worker ran.
  let(:after_request) { ->(_request, _answer) { } }
  # The owner's relay; under the legacy owner the writers write the table.
  let(:relay_run) { -> { } }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      Timekeeping::InvoiceOperationWorker.new.run
      relay_run.call
      after_request.call(request, answer)
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

  def projected_state = TimesheetEntry.with_discarded.where(id: projected_entries.map(&:id)).order(:id).map(&:attributes)

  def invoices = Invoice.with_discarded.where("invoice_number LIKE ?", "%TIS-%")

  shared_examples "a run on both tenants" do
    it "keeps each tenant's entries from the other, and the admin's from the employee, and leaves only discarded entries" do
      before = projected_state
      expect { check.call }.not_to raise_error

      [tenant_a, tenant_b].each do |tenant|
        held = entries_of(tenant)
        aggregate_failures do
          # E and M only: no refused create wrote an entry, in either tenant.
          expect(held.map { |entry| entry.fetch("note") }).to contain_exactly(
            "Tenant isolation #{run_name} #{tenant.company.id} E edited by the admin", "Tenant isolation #{run_name} #{tenant.company.id} M"
          )
          expect(held).to all(include("discarded_at" => be_present))
          expect(held.find { |entry| entry["note"].end_with?(" M") }["user_id"]).to eq(tenant.admin.id)
          # Each was projected before the checks, and no forged snapshot moved it.
          expect(TimesheetEntry.with_discarded.where(id: held.map { |entry| entry.fetch("id") }).pluck(:project_id).uniq).to eq([tenant.project.id])
        end
      end
      expect(invoices).to be_empty
      expect(projected_state).to eq(before)
      expect(log.string).to include(
        "and the projection holds both",
        "could not read, write, prepare or project Tenant isolation business 2's entry",
        "could not read, write, prepare or project Tenant isolation business 1's entry",
        "which is unchanged on its owner and in the projection",
        "the employee's create for the admin was refused (A2)",
        "the admin's web edit of entry",
        "on 2 businesses, under owner #{ownership[:owner]} at generation #{ownership[:generation]}; the single-writer guard reported nothing here"
      )
    end
  end

  context "when the legacy owner holds the entries" do
    def entries_of(tenant)
      TimesheetEntry.with_discarded.where(project: tenant.project).where("note LIKE ?", "Tenant isolation%").map(&:attributes)
    end

    it_behaves_like "a run on both tenants"

    context "when an entry of another business can be found" do
      before do
        allow(Timekeeping::EntryReads).to receive(:call).and_wrap_original do |original, read|
          read.is_a?(Timekeeping::EntryReads::Find) ? TimesheetEntry.kept.find(read.id) : original.call(read)
        end
      end

      it "fails, naming the read that found it" do
        expect { check.call }.to raise_error(
          described_class::Failed, /the owner's read of Tenant isolation business 2's entry \d+, in Tenant isolation business 1, found it/
        )
      end
    end

    context "when the projection consumer takes a snapshot of another business" do
      before { allow_any_instance_of(Timekeeping::ProjectionConsumer).to receive(:foreign_entry_ids).and_return([]) }

      it "fails, naming the snapshot that was not refused" do
        expect { check.call }.to raise_error(described_class::Failed, /a snapshot moving .*'s projected entry \d+ into .* answered 200/)
      end
    end

    context "when the employee may edit any entry of the business" do
      before { allow_any_instance_of(TimesheetEntryPolicy).to receive(:update?).and_return(true) }

      it "fails at the employee's edit of the admin's entry" do
        expect { check.call }.to raise_error(described_class::Failed, /the employee's edit of the admin's entry \d+ answered 200 .*, not 403/)
      end
    end
  end

  context "when the prepared application owns the entries, after a rollback" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application") }
    let(:relay_run) { -> { Timekeeping::LocalRelay.new.run } }

    before { advance_local_entry_ids! }

    def entries_of(tenant)
      Timekeeping::Entry.where(company_id: tenant.company.id).where("note LIKE ?", "Tenant isolation%").map { |entry| entry.to_contract }
    end

    it_behaves_like "a run on both tenants"

    context "when a write reaches timesheet_entries outside the projection consumer" do
      let(:after_request) do
        lambda do |request, _answer|
          next unless request.path == "/api/v1/timesheet_entry" && request.method == "POST"

          TimesheetEntry.where(id: projected_entries.first.id).update_all(note: "written outside the consumer")
        end
      end

      it "fails once the run ends, naming the single-writer guard's violations" do
        expect { check.call }.to raise_error(described_class::Failed, /the single-writer guard reported \d+ violations while the run wrote/)
      end
    end
  end

  context "when Timekeeping owns the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
    let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
    let(:relay) { TimekeepingContracts::FakeRelay.new }
    let(:relay_run) do
      lambda do
        next if fake.entries.empty?

        relay.deliver(Rails.application, fake.entries.map do |entry|
          relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                         **entry.except("id", "company_id", "version").symbolize_keys)
        end)
      end
    end

    after { expect(fake.violations).to be_empty }

    def entries_of(tenant)
      fake.entries.select { |held| held["company_id"] == tenant.company.id }
    end

    it_behaves_like "a run on both tenants"

    it "also sends the show, edit and discard of the other's entry straight to Timekeeping under its own claims" do
      check.call

      straight = fake.calls.select { |call| %i[show_entry update_entry discard_entry].include?(call.operation) }
      expect(straight.map(&:operation)).to include(:show_entry, :update_entry, :discard_entry)
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff, admission closed") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.call }.to raise_error(described_class::Failed, /admission is open, under any owner/)
      expect(TimesheetEntry.where("note LIKE ?", "Tenant isolation%")).to be_empty
    end
  end

  it "refuses a run with one business" do
    single = described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run: run_name,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants: tenants.first(1))
    )

    expect { single.call }.to raise_error(described_class::Failed, /needs two businesses/)
  end

  it "refuses a run name that could not be part of an invoice number" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
