# frozen_string_literal: true

require "rails_helper"

# The user-hard-delete proof (Timekeeping::UserDeleteRefusedCheck; docs/
# architecture/timekeeping-soa.md §12.4, §10.1), run in process through the
# real controllers on two tenants, under both owners it runs under: Timekeeping
# (its consumer-side fake, FakeTimekeeping, holds the entries, and FakeRelay
# delivers them), and the prepared application after a rollback (its own entry
# table, and Timekeeping::LocalRelay). The relay delivers after every request
# only while `relaying` is on, as the owner's relay does once it is started
# again. These examples pin the two halves' writes and checks, and that each
# check fails the run when what it checks does not hold. Against the two
# running applications it runs as bin/timekeeping-demo user-delete-refused.
RSpec.describe Timekeeping::UserDeleteRefusedCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "User delete business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
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
      deliver if @relaying
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

  def resume_relay!
    @relaying = true
    deliver
  end

  def subject_of(tenant) = User.find_by!(email: "delete-refused-#{run_name.downcase}-#{tenant.company.id}@#{described_class::DOMAIN}")

  def super_admin = User.find_by!(email: SuperAdmin::SUPER_ADMIN_EMAILS.first)

  def delete_audits = Audited::Audit.where(action: "super_admin_delete")

  before do
    tenants
    set_timekeeping_ownership!(ownership)
    @relaying = false
  end

  shared_examples "the user-hard-delete proof" do |owner:, relay:|
    it "names #{relay} as the service holding the owner's relay" do
      expect(check.relay).to eq(relay)
    end

    it "with the relay paused, refuses the super-admin delete of a user whose first entry is not yet projected, on both tenants" do
      check.paused

      [tenant_a, tenant_b].each do |tenant|
        user = subject_of(tenant)
        entry = entry_of(user)
        expect(entry).to include("note" => "User delete refused #{run_name}", "duration" => 35.0, "company_id" => tenant.company.id)
        expect(TimesheetEntry.unscoped.exists?(entry["id"])).to be(false)
        expect(user).to have_attributes(confirmed?: true, current_workspace_id: tenant.company.id)
        expect(user).to have_role(:employee, tenant.company)
        expect(Agent.where(user:).sole).to have_attributes(company_id: tenant.company.id, name: "Delete refused #{run_name}")
      end
      expect(super_admin).to be_super_admin
      expect(delete_audits).to be_empty
      expect(log.string).to include(
        "the delete of user #{subject_of(tenant_a).id}, whose first entry",
        "with the relay paused, the super-admin delete of a user with a first, unprojected entry was refused on 2 businesses, " \
        "under owner #{owner}"
      )
    end

    it "once the relay resumes, sees the projection hold the entry under the user, then discards it and keeps the user" do
      check.paused
      resume_relay!
      check.resumed

      [tenant_a, tenant_b].each do |tenant|
        user = subject_of(tenant)
        entry = entry_of(user)
        expect(entry).to include("discarded_at" => be_present)
        expect(TimesheetEntry.unscoped.find(entry["id"])).to have_attributes(user_id: user.id, discarded_at: be_present)
        expect(Agent.where(user:)).to exist
      end
      expect(log.string).to include("once the relay resumed, the refused users' entries were projected on 2 businesses, under owner #{owner}")
    end

    context "when the relay is not paused" do
      before { @relaying = true }

      it "fails before attempting the delete, since an entry the projection already holds proves nothing" do
        expect { check.paused }.to raise_error(described_class::Failed, /the projection already holds entry \d+, so the relay is not paused/)
        expect(delete_audits).to be_empty
      end
    end

    it "fails the resumed half when the relay stays stopped" do
      check.paused

      expect { check.resumed }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the projection holds entry \d+ for user \d+/)
    end

    it "fails the resumed half when the paused half did not run under that name" do
      check.paused

      expect { check(run: "another-run").resumed }.to raise_error(described_class::Failed, /no user delete-refused-another-run-\d+@/)
    end

    it "fails a second paused half under the same name, as its user already exists" do
      check.paused

      expect { check.paused }.to raise_error(described_class::Failed, /already exists; give each run its own name/)
    end

    context "when the delete is not refused" do
      # The gate the proof is for, removed: the destroy runs as before the
      # first handoff.
      before { allow(Timekeeping::Ownership).to receive(:handoff_begun?).and_return(false) }

      it "fails, naming what the destroy answered" do
        expect { check.paused }.to raise_error(described_class::Failed, /the super-admin delete of user \d+ answered 200 .*not 422/)
      end
    end
  end

  context "when Timekeeping owns the entries" do
    let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }
    let(:relay) { TimekeepingContracts::FakeRelay.new }

    around do |example|
      config = Rails.configuration.x.timekeeping
      url, key = config.url, config.token_key
      config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
      example.run
    ensure
      config.url, config.token_key = url, key
    end

    after { expect(fake.violations).to be_empty }

    def deliver
      return if fake.entries.empty?

      relay.deliver(Rails.application, fake.entries.map do |entry|
        relay.snapshot(entry_id: entry["id"], version: entry["version"], company_id: entry["company_id"],
                       **entry.except("id", "company_id", "version").symbolize_keys)
      end)
    end

    def entry_of(user) = fake.entries.find { |held| held["user_id"] == user.id }

    include_examples "the user-hard-delete proof", owner: "timekeeping", relay: "timekeeping-relay"
  end

  context "when the prepared application owns the entries, after a rollback" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application") }

    before { advance_local_entry_ids! }

    def deliver = Timekeeping::LocalRelay.new.run

    def entry_of(user)
      held = Timekeeping::Entry.where(user_id: user.id).sole
      held.attributes.slice("id", "note", "duration", "company_id", "discarded_at")
    end

    include_examples "the user-hard-delete proof", owner: "monolith", relay: "miru-jobs"
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses each half, and names no relay, before anything is written" do
      expect { check.relay }.to raise_error(described_class::Failed, /owns the entries with admission open .*owner legacy/)
      expect { check.paused }.to raise_error(described_class::Failed, /owns the entries with admission open/)
      expect { check.resumed }.to raise_error(described_class::Failed, /owns the entries with admission open/)
      expect(User.where("email LIKE ?", "delete-refused-%")).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.paused }.to raise_error(described_class::Failed, /admission open/)
      expect(User.where("email LIKE ?", "delete-refused-%")).to be_empty
    end
  end

  it "refuses a run name that could not be part of an email address" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
