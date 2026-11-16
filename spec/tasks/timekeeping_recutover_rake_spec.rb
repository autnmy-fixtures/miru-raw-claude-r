# frozen_string_literal: true

require "rails_helper"
require "rake"

# The runner for the re-cutover from the prepared application back to
# Timekeeping (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5) in
# the local demo (§11.2). Each invocation stands for its own process: it
# builds a new handoff tool, which knows only what the journal file kept, so
# a run that stops is resumed by the next invocation. Timekeeping is the
# consumer-side fake of its handoff API (§12.3), whose relay delivers into the
# real projection endpoint. The re-cutover starts where the demo reaches it:
# after the first cutover and the rollback, with a write on each tenant the
# `monolith` owner took through the gateway and its local relay has not yet
# projected.
RSpec.describe "timekeeping:recutover", type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-recutover")) }
  let(:journal_path) { directory.join("recutover.json") }

  let!(:fake) { TimekeepingContracts::FakeHandoff.new.install! }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 90.7) }
  let!(:linked_entry) { unbilled_entry(tenant_b) }
  let!(:draft) { invoice_for(tenant_a).tap { |invoice| direct_line(invoice, draft_entry).then { invoice.reload.save! } } }
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  before do
    allow(Rails.configuration.x.timekeeping).to receive_messages(
      url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY
    )
    stub_const("ENV", ENV.to_h.merge("JOURNAL" => journal_path.to_s))
  end

  # The first cutover, Timekeeping's write as the owner, the rollback, then
  # the monolith owner's writes, not yet relayed. Timekeeping's relay runs
  # whenever the first cutover or the rollback waits for it.
  before do
    relaying = Timekeeping::FirstCutover::Drain.new(pause: ->(_seconds) { fake.relay! })
    quiet = Logger.new(nil)
    Timekeeping::FirstCutover.new(unlocked_link_invoice_ids: [unlocked_link_invoice.id], drain: relaying, logger: quiet).call
    fake.write!(fake.held.fetch("entries").find { |held| held.fetch("id") == linked_entry.id }.merge("note" => "Proofing", "version" => 2))
    Timekeeping::Rollback.new(drain: relaying, logger: quiet).call

    @written = [log_after_rollback!(tenant_a, duration: 45.5), log_after_rollback!(tenant_b, duration: 0.1)]
    @rollback_calls = fake.calls.size
  end

  # The local relay runs whenever the re-cutover waits for it, as its worker
  # would.
  let(:relaying_locally) { Timekeeping::FirstCutover::Drain.new(pause: ->(_seconds) { Timekeeping::LocalRelay.new.run }) }

  before do
    drain = relaying_locally
    allow(Timekeeping::FirstCutover::Drain).to receive(:new).and_return(drain)
  end

  # The money no handoff may move, as it stood once the rollback was done.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  after do
    FileUtils.rm_rf(directory)
    expect(fake.violations).to be_empty
  end

  # The rollback's load and the monolith owner's creates move the prepared
  # application's entry and audit sequences, which no fixture transaction
  # rolls back; put back what they found.
  def sequence_state(model)
    model.connection.select_rows("SELECT last_value, is_called FROM #{model.connection.quote_table_name(model.sequence_name)}").first
  end

  around do |example|
    found = [Timekeeping::Entry, Timekeeping::EntryAudit].index_with { |model| sequence_state(model) }
    example.run
  ensure
    found&.each do |model, (value, called)|
      model.connection.select_value("SELECT setval(#{model.connection.quote(model.sequence_name)}, #{Integer(value)}, #{called})")
    end
  end

  # One entry the `monolith` owner accepts after the rollback, through the
  # gateway as a controller hands it over. Answers the prepared
  # application's entry.
  def log_after_rollback!(tenant, duration:)
    Current.user = tenant.employee
    Current.company = tenant.company
    Timekeeping::Gateway.call(
      Timekeeping::Gateway::CreateEntry.new(
        project: tenant.project, user: tenant.employee, writer: "web",
        attributes: ActionController::Parameters.new(duration: duration.to_s, work_date: "2026-11-09", note: "After rollback").permit!
      )
    )
    Timekeeping::Entry.where(note: "After rollback").order(:id).last
  ensure
    Current.reset
  end

  # Runs one invocation, as its own process would: the task's output, and its
  # exit status (0 when it returns).
  def run_task(name = "timekeeping:recutover")
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

  def recutover_calls = fake.calls.drop(@rollback_calls)
  def steps_run = recutover_calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }

  def rolled_back = [[2, "monolith", "open"], [2, "monolith", "open"]]
  def recut_over = [[3, "timekeeping", "open"], [3, "timekeeping", "open"]]
  def aborted = [[3, "monolith", "open"], [3, "monolith", "open"]]

  def written_ids = @written.map(&:id)
  def carried = fake.held.fetch("entries").select { |entry| written_ids.include?(entry.fetch("id")) }

  def kept = Timekeeping::RecutoverJournal.new(path: journal_path).resume

  def money_unchanged? = Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process).empty?

  it "starts from the rollback, with the monolith owner's writes not yet projected" do
    expect(copies).to eq(rolled_back)
    expect(Timekeeping::OutboxSnapshot.undelivered.pluck(:entry_id)).to eq(written_ids)
    expect(TimesheetEntry.where(id: written_ids)).to be_empty
  end

  it "runs the whole re-cutover, carrying the monolith owner's writes to Timekeeping, reports it, and forgets the journal" do
    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("Timekeeping re-cutover: close_local at generation 3")
    expect(output).to include(
      "done at generation 3, Timekeeping owns entries (reconciled: #{TimesheetEntry.count} entries, 2 reservations, "
    )
    expect(copies).to eq(recut_over)
    expect(steps_run).to eq(%w[close freeze flip])
    expect(Timekeeping::OutboxSnapshot.undelivered).to be_empty
    expect(carried.pluck("duration")).to contain_exactly(45.5, 0.1)
    expect(fake.held.fetch("entries").pluck("id")).to eq(TimesheetEntry.order(:id).ids)
    expect(fake.held.fetch("entries").find { |held| held.fetch("id") == linked_entry.id }.slice("note", "version"))
      .to eq("note" => "Proofing", "version" => 2)
    expect(fake.held.fetch("reservations").map { |row| row.values_at("entry_id", "edit_lock") })
      .to contain_exactly([draft_entry.id, true], [linked_entry.id, false])
    expect(journal_path).not_to exist
    expect(money_unchanged?).to be(true)
  end

  it "resumes in a later invocation, from the journal, a run whose step response was lost" do
    fake.lose_next_response(:run_step)

    output, status = run_task
    expect(status).to eq(1)
    expect(output).to include("stopped: Timekeeping::HandoffClient::Unavailable", "Run bin/rails timekeeping:recutover again to resume")
    expect(copies).to eq([[3, "monolith", "closed"], [3, "monolith", "closed"]])
    expect(kept.financial_snapshot).to eq(money_before)

    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("freeze_local at generation 3", "done at generation 3")
    expect(output).not_to include("close_local")
    expect(copies).to eq(recut_over)
    expect(steps_run).to eq(%w[close freeze flip])
    expect(carried.size).to eq(2)
    expect(journal_path).not_to exist
    expect(money_unchanged?).to be(true)
  end

  it "stops, both copies frozen, while the local relay is not running, and resumes once it runs" do
    now = 0
    stalled = relaying_locally.with(timeout: 5, pause: ->(seconds) { now += seconds }, clock: -> { now })
    allow(Timekeeping::FirstCutover::Drain).to receive(:new).and_return(stalled)

    output, status = run_task
    expect(status).to eq(1)
    expect(output).to include("stopped: Timekeeping::Recutover::DrainTimeout", "2 snapshots undelivered after 5 s")
    expect(copies).to eq([[3, "monolith", "frozen"], [3, "monolith", "frozen"]])
    expect(recutover_calls.map(&:operation)).not_to include(:load_recutover_checkpoint)
    expect(kept.financial_snapshot).to eq(money_before)

    allow(Timekeeping::FirstCutover::Drain).to receive(:new).and_return(relaying_locally)
    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("transfer at generation 3", "done at generation 3")
    expect(copies).to eq(recut_over)
    expect(carried.size).to eq(2)
    expect(journal_path).not_to exist
  end

  it "checks the money of a resumed run against the snapshot the journal kept, not one of its own" do
    fake.lose_next_response(:run_step)
    expect(run_task.last).to eq(1)
    line = draft.invoice_line_items.first
    recorded = kept.financial_snapshot.deep_dup
    recorded.fetch("invoice_line_items").fetch(line.id.to_s)["rate"] = "1.00"
    Timekeeping::RecutoverJournal.new(path: journal_path).record(Timekeeping::Recutover::Resume.new(financial_snapshot: recorded))

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("aborted at reconcile_local", "  money_differs: invoice_line_items/#{line.id}/rate")
    expect(copies).to eq(aborted)
    expect(journal_path).not_to exist
  end

  it "reports a re-cutover that is already done, changing nothing" do
    expect(run_task.last).to eq(0)
    calls = fake.calls.size

    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("done at generation 3, Timekeeping owns entries (reconciled earlier)")
    expect(fake.calls.drop(calls).map(&:operation)).to eq(%i[read_handoff])
    expect(copies).to eq(recut_over)
  end

  it "aborts both copies on a refusal no retry changes, lists what was found, and forgets the journal" do
    fake.fail_next(:load_recutover_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "entry_behind" => [linked_entry.id] })

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("aborted at load", "  entry_behind: #{linked_entry.id}")
    expect(copies).to eq(aborted)
    expect(steps_run).to eq(%w[close freeze abort])
    expect(journal_path).not_to exist
  end

  it "refuses a journal it cannot read, leaving both copies and the file as they are" do
    journal_path.write("{")

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("re-cutover journal", "cannot be read")
    expect(journal_path.read).to eq("{")
    expect(recutover_calls).to be_empty
    expect(copies).to eq(rolled_back)
  end

  it "refuses the rollback's journal handed to it, leaving both copies and the file as they are" do
    Timekeeping::RollbackJournal.new(path: journal_path).record(Timekeeping::Rollback::Resume.new(financial_snapshot: money_before))
    content = journal_path.read

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("re-cutover journal", "cannot be read")
    expect(journal_path.read).to eq(content)
    expect(recutover_calls).to be_empty
    expect(copies).to eq(rolled_back)
  end

  describe "timekeeping:recutover:abort" do
    it "reopens admission on both copies of a stopped run under the prepared application, and forgets the journal" do
      fake.lose_next_response(:run_step)
      expect(run_task.last).to eq(1)
      expect(journal_path).to exist

      output, status = run_task("timekeeping:recutover:abort")

      expect(status).to eq(0)
      expect(output).to include("aborted at generation 3, admission reopened on both copies under the prepared application")
      expect(copies).to eq(aborted)
      expect(steps_run).to eq(%w[close abort])
      expect(journal_path).not_to exist
    end

    it "lets a later invocation re-cut over after the abort, carrying what the monolith owner wrote since" do
      fake.lose_next_response(:run_step)
      expect(run_task.last).to eq(1)
      expect(run_task("timekeeping:recutover:abort").last).to eq(0)
      @written << log_after_rollback!(tenant_a, duration: 12.25)

      output, status = run_task

      expect(status).to eq(0)
      expect(output).to include("close_local at generation 4", "done at generation 4")
      expect(copies).to eq([[4, "timekeeping", "open"], [4, "timekeeping", "open"]])
      expect(carried.pluck("duration")).to contain_exactly(45.5, 0.1, 12.25)
      expect(money_unchanged?).to be(true)
    end

    it "refuses when no re-cutover is in progress, changing nothing" do
      output, status = run_task("timekeeping:recutover:abort")

      expect(status).to eq(1)
      expect(output).to include("nothing to abort")
      expect(copies).to eq(rolled_back)
    end
  end
end
