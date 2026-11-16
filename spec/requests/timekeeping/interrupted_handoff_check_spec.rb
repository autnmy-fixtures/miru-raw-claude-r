# frozen_string_literal: true

require "rails_helper"

# The interrupted-and-resumed-handoff proof (Timekeeping::InterruptedHandoffCheck;
# docs/architecture/timekeeping-soa.md §13 item 6, §10.5), run in process
# through the real controllers on two tenants. Timekeeping's handoff API is
# its consumer-side fake (FakeHandoff).
#
# The interruptions are the real first cutover (Timekeeping::FirstCutover)
# with its journal in a file, stopped where the demo stops it: in its
# transfer's wait for the relay, once by an exception raised there (the
# SIGKILL), once by its drain timeout. The resumed step runs after a stand-in
# for the rollback's end, under the prepared application, whose entries,
# reservations, invoice operation worker and local relay all run in process.
# These examples pin each step's writes and checks, and that each check fails
# the run when what it checks does not hold. Against the two running
# applications it runs as bin/timekeeping-demo interrupted-handoff, under each
# of the three owners.
RSpec.describe Timekeeping::InterruptedHandoffCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Interrupted handoff business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:directory) { Dir.mktmpdir("interrupted-handoff") }
  let(:journals) do
    { "legacy" => "first_cutover.json", "timekeeping" => "rollback.json" }.transform_values { |name| File.join(directory, name) }
  end
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T120000Z-ab12" }
  let(:handoff_client) do
    Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY)
  end

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
  def check
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run: run_name,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:, directory:, journals:, handoff_client:)
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
    @relaying = false
  end

  # What miru-jobs does between requests: the invoice operation worker
  # delivers commit and abort, and, while it runs, the prepared application's
  # local relay projects its entries.
  def run_workers
    Timekeeping::InvoiceOperationWorker.new.run
    Timekeeping::LocalRelay.new.run if @relaying
  end

  def state = JSON.parse(Pathname(directory).join(run_name, "state.json").read)

  def note(name) = "Interrupted handoff #{run_name} #{name}"

  def draft_of(tenant)
    Invoice.with_discarded.where(company: tenant.company).find_by("invoice_number LIKE ?", "%IHO-#{tenant.company.id}-#{run_name}")
  end

  describe "#plan" do
    {
      "first handoff aborted" => "timekeeping:first_cutover timekeeping-relay",
      "cut over to Timekeeping" => "timekeeping:rollback timekeeping-relay",
      "rolled back to the prepared application" => "timekeeping:recutover miru-jobs"
    }.each do |ownership, plan|
      it "names #{plan.inspect} when #{ownership}" do
        set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch(ownership))

        expect(check.plan).to eq(plan)
      end
    end

    it "fails while a handoff has admission closed" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen"))

      expect { check.plan }.to raise_error(described_class::Failed, /starts with admission open, under any owner; ownership is generation 2/)
    end
  end

  context "when the first cutover is interrupted in its transfer" do
    let!(:fake_handoff) { TimekeepingContracts::FakeHandoff.new.install! }
    let(:journal) { Timekeeping::FirstCutoverJournal.new(path: journals.fetch("legacy")) }
    let(:killed) { Class.new(StandardError) }

    after { expect(fake_handoff.violations).to be_empty }

    def cutover(drain)
      Timekeeping::FirstCutover.new(client: handoff_client, journal:, drain:, logger: Logger.new(nil))
    end

    # The run the demo kills: it dies inside its transfer's wait for the
    # relay, after the load, as SIGKILL leaves it.
    def run_killed!
      kill = killed
      expect { cutover(Timekeeping::FirstCutover::Drain.new(timeout: 600, pause: ->(_seconds) { raise kill })).call }
        .to raise_error(killed)
    end

    # The run the demo lets stop: its drain times out, for a resume.
    def run_stopped!
      now = 0
      drain = Timekeeping::FirstCutover::Drain.new(timeout: 5, pause: ->(seconds) { now += seconds }, clock: -> { now })
      expect { cutover(drain).call }.to raise_error(Timekeeping::FirstCutover::DrainTimeout)
    end

    def copies
      local = Timekeeping::Ownership.current
      [[local.generation, local.owner, local.state], fake_handoff.copy.to_h.values_at(:generation, :owner, :state)]
    end

    def interrupted!
      check.held
      check.paused
      run_killed!
      check.transferring
      check.crashed
    end

    it "writes X and Y before the handoff, then sees it killed and stopped in its transfer, fenced each time, on both tenants" do
      interrupted!
      run_stopped!
      check.timed_out

      expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
      expect(journal.resume.checkpoint.generation).to eq(1)
      expect(fake_handoff.undelivered).not_to be_empty
      [tenant_a, tenant_b].each do |tenant|
        row = state.fetch("tenants").find { |written| written["company_id"] == tenant.company.id }
        draft = draft_of(tenant)
        expect(TimesheetEntry.find(row["x"])).to have_attributes(note: note("X, edited"), duration: 35.0, locked: true)
        expect(TimesheetEntry.find(row["y"])).to have_attributes(note: note("Y, edited"), duration: 45.0, locked: false)
        expect(draft).to have_attributes(status: "draft", id: row["draft_id"])
        expect(draft.invoice_line_items.sole.timesheet_entry_id).to eq(row["x"])
      end
      expect(TimesheetEntry.where(note: note("Y, refused"))).to be_empty
      expect(Invoice.where("invoice_number LIKE ?", "%-REFUSED")).to be_empty
      expect(state).to include("owner" => "legacy", "generation" => 0, "journal" => be_present)
      expect(log.string).to include(
        "entry X was written and reserved by a draft on 2 businesses, under generation 0, owner legacy, state open",
        "with timekeeping-relay stopped, entry Y was written on 2 businesses",
        "the handoff stands in its transfer: both copies frozen at generation 1 under legacy",
        "the checkpoint loaded; kill it now",
        "Interrupted handoff business 1: an entry create, an edit of entry Y",
        "the handoff killed in its transfer left both copies frozen at generation 1 under legacy, its journal holding the " \
        "financial snapshot its close took",
        "the handoff stopped in its transfer for a resume left both copies frozen at generation 1 under legacy"
      )
    end

    it "fails to see the handoff in its transfer when no run reached it" do
      check.held
      check.paused

      expect { check.transferring }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the handoff stands in its transfer/)
    end

    it "fails when the handoff is not frozen after the kill" do
      check.held
      check.paused

      expect { check.crashed }.to raise_error(described_class::Failed, /expected both copies frozen at generation 1 under legacy/)
    end

    it "fails when an entry changes on the owner while the handoff stands interrupted" do
      interrupted!
      TimesheetEntry.find(state.fetch("tenants").first.fetch("y")).update_columns(note: "moved")

      expect { check.timed_out }.to raise_error(described_class::Failed, /business 1: entry Y \d+ on the owner moved from/)
    end

    it "fails when the resumed run took another financial snapshot than the killed one" do
      interrupted!
      resume = journal.resume
      journal.record(resume.with(financial_snapshot: resume.financial_snapshot.merge("invoices" => {})))

      expect { check.timed_out }.to raise_error(described_class::Failed, /journal no longer holds what the killed run took/)
    end

    # With the generation fence let through, the entry create is written.
    it "fails when a write is accepted while the handoff stands interrupted" do
      interrupted!
      allow(Timekeeping::Ownership).to receive(:admit!).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
      rescue Timekeeping::Ownership::Moving
        Timekeeping::Ownership.current
      end

      expect { check.timed_out }.to raise_error(described_class::Failed, /business 1: the employee's create of an entry answered 200/)
    end
  end

  # The prepared application is the incoming owner of the rollback, and every
  # part of it runs in process. The run's X, Y and draft are written under it,
  # and the state is then the one the held and paused steps leave under
  # Timekeeping at generation 1, with the snapshot the crashed step keeps:
  # the stand-in for the rollback, which carries them across unchanged.
  context "when the rollback has been resumed to its end" do
    let(:handed_over) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application") }
    # Timekeeping's copy, as the rollback's flip left it.
    let(:remote_copy) { handed_over }
    let!(:fake_handoff) { TimekeepingContracts::FakeHandoff.new(**remote_copy).install! }
    let(:state_path) { Pathname(directory).join(run_name, "state.json") }

    before do
      set_timekeeping_ownership!(handed_over)
      advance_local_entry_ids!
      check.held
      check.paused
      state_path.write(JSON.generate(state.merge(
        "owner" => "timekeeping", "generation" => 1, "financial_snapshot" => Timekeeping::FinancialSnapshot.process
      )))
      # The script starts the relay again before it resumes the handoff.
      @relaying = true
      Timekeeping::LocalRelay.new.run
    end

    it "sees money, entries and the reservation kept, then writes accepted again, on both tenants" do
      check.resumed

      [tenant_a, tenant_b].each do |tenant|
        row = state.fetch("tenants").find { |written| written["company_id"] == tenant.company.id }
        expect(Timekeeping::Entry.find(row["x"])).to have_attributes(note: note("X, edited"), discarded_at: be_present)
        expect(Timekeeping::Entry.find(row["y"])).to have_attributes(note: note("Y, after the handoff"), duration: 55.0, discarded_at: be_present)
        expect(TimesheetEntry.unscoped.find(row["y"])).to have_attributes(note: note("Y, after the handoff"), discarded_at: be_present)
        expect(draft_of(tenant)).to be_discarded
        expect(Timekeeping::Reservation.where(entry_id: row["x"]).pluck(:disposition)).not_to include("active")
      end
      expect(log.string).to include(
        "the financial snapshot is identical to the one the handoff's close took",
        "Interrupted handoff business 1: entries X",
        "read back on the incoming owner and in the projection as last written, X still reserved by draft",
        "the handoff resumed to its end (generation 2, owner monolith, state open) with money unchanged, every entry and " \
        "reservation kept, and writes accepted again, on 2 businesses"
      )
    end

    context "when Timekeeping's copy has not flipped" do
      let(:remote_copy) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

      it "fails" do
        expect { check.resumed }.to raise_error(described_class::Failed, /monolith owning the entries with admission open at generation 2 on both copies/)
      end
    end

    it "fails while the handoff's journal is still there" do
      Timekeeping::RollbackJournal.new(path: journals.fetch("timekeeping")).record(Timekeeping::Rollback::Resume.new)

      expect { check.resumed }.to raise_error(described_class::Failed, /the handoff finished, but its journal .*rollback.json is still there/)
    end

    it "fails when the handoff changed money" do
      draft_of(tenant_b).update_columns(amount: 1)

      expect { check.resumed }.to raise_error(described_class::Failed, /the interrupted handoff changed money: .*column: "amount"/)
    end

    it "fails when the draft no longer holds X" do
      Timekeeping::Reservation.where(invoice_id: draft_of(tenant_a).id).delete_all

      expect { check.resumed }.to raise_error(described_class::Failed, /business 1: the candidates offer entry X \d+, which draft \d+ holds/)
    end
  end

  it "fails a step that finds no held step for its run" do
    expect { check.crashed }.to raise_error(described_class::Failed, /no held step for run #{run_name}/)
  end
end
