# frozen_string_literal: true

require "rails_helper"
require "rake"

# The runner for the first cutover (docs/architecture/timekeeping-soa.md
# §10.2 step 5, §10.5) in the local demo (§11.2). Each invocation stands for
# its own process: it builds a new handoff tool, which knows only what the
# journal file kept, so a run that stops is resumed by the next invocation.
# Timekeeping is the consumer-side fake of its handoff API (§12.3), whose
# relay delivers into the real projection endpoint.
RSpec.describe "timekeeping:first_cutover", type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-first-cutover")) }
  let(:journal_path) { directory.join("first_cutover.json") }
  let(:disposition_path) { directory.join("disposition.yml") }

  let!(:fake) { TimekeepingContracts::FakeHandoff.new.install! }

  # The company factory names every company alike; a disposition names them.
  before do
    tenant_a.company.update!(name: "Fork & Leaf Salads")
    tenant_b.company.update!(name: "Copper Kettle Bakery")
  end

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 90.7) }
  let!(:linked_entry) { unbilled_entry(tenant_b) }
  let!(:draft) { invoice_for(tenant_a).tap { |invoice| direct_line(invoice, draft_entry).then { invoice.reload.save! } } }
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  before do
    %w[timekeeping:first_cutover timekeeping:first_cutover:abort].each { |name| Rake::Task[name].reenable }
    allow(Rails.configuration.x.timekeeping).to receive_messages(
      url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY
    )
    # The relay runs whenever the tool waits for it.
    drain = Timekeeping::FirstCutover::Drain.new(pause: ->(_seconds) { fake.relay! })
    allow(Timekeeping::FirstCutover::Drain).to receive(:new).and_return(drain)
    disposition_path.write(
      { "unlocked_links" => {
        "disposition" => "active_without_edit_lock",
        "invoices" => { tenant_b.company.name => [unlocked_link_invoice.invoice_number] }
      } }.to_yaml
    )
    stub_const("ENV", ENV.to_h.merge("JOURNAL" => journal_path.to_s, "DISPOSITION" => disposition_path.to_s))
  end

  after do
    FileUtils.rm_rf(directory)
    expect(fake.violations).to be_empty
  end

  # Runs one invocation, as its own process would: the task's output, and its
  # exit status (0 when it returns).
  def run_task(name = "timekeeping:first_cutover")
    Rake::Task[name].reenable
    status = 0
    output = capture_output do
      Rake::Task[name].invoke
    rescue SystemExit => error
      status = error.status
    end
    [output, status]
  end

  def capture_output
    stdout, stderr = $stdout, $stderr
    $stdout = $stderr = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout, $stderr = stdout, stderr
  end

  def copies
    local = Timekeeping::Ownership.current
    [[local.generation, local.owner, local.state], fake.copy.to_h.values_at(:generation, :owner, :state)]
  end

  def steps_run = fake.calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }

  def cut_over = [[1, "timekeeping", "open"], [1, "timekeeping", "open"]]

  it "runs the whole first cutover, reports it, and forgets the journal" do
    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("Timekeeping first cutover: close_local at generation 1")
    expect(output).to include("done at generation 1, Timekeeping owns entries (reconciled: #{TimesheetEntry.count} entries, 2 reservations)")
    expect(copies).to eq(cut_over)
    expect(fake.loaded.fetch("reservations").map { |reservation| reservation.values_at("entry_id", "edit_lock") })
      .to contain_exactly([draft_entry.id, true], [linked_entry.id, false])
    expect(journal_path).not_to exist
    expect(Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process)).to be_empty
  end

  it "resumes in a later invocation, from the journal, a run whose load response was lost after the load ran" do
    fake.lose_next_response(:load_checkpoint)

    output, status = run_task
    expect(status).to eq(1)
    expect(output).to include("stopped: Timekeeping::HandoffClient::Unavailable", "Run bin/rails timekeeping:first_cutover again to resume")
    expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
    kept = Timekeeping::FirstCutoverJournal.new(path: journal_path).resume
    expect(kept.checkpoint.entries).to eq(fake.loaded.fetch("entries"))
    fake.relay! # the relay keeps running between the two processes

    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("load at generation 1: already loaded, reconciling it", "done at generation 1")
    expect(copies).to eq(cut_over)
    expect(steps_run).to eq(%w[close freeze flip])
    expect(journal_path).not_to exist
    expect(Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process)).to be_empty
  end

  it "resumes in a later invocation a run stopped before the load, reusing the journal's financial snapshot" do
    fake.fail_next(:load_checkpoint, status: 503, slug: "ownership-moving", retryable: true)

    expect(run_task.last).to eq(1)
    kept = Timekeeping::FirstCutoverJournal.new(path: journal_path).resume
    expect(fake.loaded).to be_nil
    expect(kept.financial_snapshot).to eq(money_before)

    expect(run_task.last).to eq(0)
    expect(fake.loaded.fetch("entries")).to eq(kept.checkpoint.entries)
    expect(copies).to eq(cut_over)
  end

  it "aborts both copies on a refusal no retry changes, lists what was found, and forgets the journal" do
    fake.fail_next(:reconcile_checkpoint, status: 409, slug: "checkpoint-differs", lists: { "entry_differs" => [linked_entry.id] })

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("aborted at reconcile_remote", "  entry_differs: #{linked_entry.id}")
    expect(copies).to eq([[1, "legacy", "open"], [1, "legacy", "open"]])
    expect(journal_path).not_to exist
  end

  it "refuses a disposition that does not resolve, changing nothing" do
    disposition_path.write({ "unlocked_links" => { "disposition" => "active_without_edit_lock", "invoices" => { "Nobody" => ["X-1"] } } }.to_yaml)

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("Nobody X-1 is not exactly one invoice")
    expect(copies).to eq([[0, "legacy", "open"], [0, "legacy", "open"]])
    expect(fake.calls).to be_empty
  end

  it "refuses a journal it cannot read, leaving both copies and the file as they are" do
    journal_path.write("{")

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("cannot be read")
    expect(journal_path.read).to eq("{")
    expect(fake.calls).to be_empty
  end

  describe "timekeeping:first_cutover:abort" do
    it "reopens admission on both copies of a stopped run, and forgets the journal" do
      fake.lose_next_response(:load_checkpoint)
      expect(run_task.last).to eq(1)
      expect(journal_path).to exist

      output, status = run_task("timekeeping:first_cutover:abort")

      expect(status).to eq(0)
      expect(output).to include("aborted at generation 1, admission reopened on both copies")
      expect(copies).to eq([[1, "legacy", "open"], [1, "legacy", "open"]])
      expect(journal_path).not_to exist
    end

    it "refuses when no handoff is in progress, changing nothing" do
      output, status = run_task("timekeeping:first_cutover:abort")

      expect(status).to eq(1)
      expect(output).to include("nothing to abort")
      expect(copies).to eq([[0, "legacy", "open"], [0, "legacy", "open"]])
    end
  end
end
