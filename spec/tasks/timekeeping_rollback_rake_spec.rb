# frozen_string_literal: true

require "rails_helper"
require "rake"

# The runner for the rollback to the prepared application
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5) in the local
# demo (§11.2). Each invocation stands for its own process: it builds a new
# handoff tool, which knows only what the journal file kept, so a run that
# stops is resumed by the next invocation. Timekeeping is the consumer-side
# fake of its handoff API (§12.3), whose relay delivers into the real
# projection endpoint. The rollback starts where the demo reaches it: after
# the first cutover, with a write Timekeeping took as the owner and has not
# yet projected.
RSpec.describe "timekeeping:rollback", type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-rollback")) }
  let(:journal_path) { directory.join("rollback.json") }

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
    # The relay runs whenever a tool waits for it.
    drain = Timekeeping::FirstCutover::Drain.new(pause: ->(_seconds) { fake.relay! })
    allow(Timekeeping::FirstCutover::Drain).to receive(:new).and_return(drain)
    stub_const("ENV", ENV.to_h.merge("JOURNAL" => journal_path.to_s))
  end

  # The first cutover, then Timekeeping's write as the owner.
  before do
    Timekeeping::FirstCutover.new(unlocked_link_invoice_ids: [unlocked_link_invoice.id], logger: Logger.new(nil)).call
    @cutover_calls = fake.calls.size
    fake.write!(fake.held.fetch("entries").find { |held| held.fetch("id") == linked_entry.id }.merge("note" => "Proofing", "version" => 2))
  end

  # The money no handoff may move, as it stood once the cutover was done.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  after do
    FileUtils.rm_rf(directory)
    expect(fake.violations).to be_empty
  end

  # The load moves the prepared application's entry and audit sequences,
  # which no fixture transaction rolls back; put back what it found.
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

  # Runs one invocation, as its own process would: the task's output, and its
  # exit status (0 when it returns).
  def run_task(name = "timekeeping:rollback")
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

  def rollback_calls = fake.calls.drop(@cutover_calls)
  def steps_run = rollback_calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }

  def rolled_back = [[2, "monolith", "open"], [2, "monolith", "open"]]
  def aborted = [[2, "timekeeping", "open"], [2, "timekeeping", "open"]]

  def kept = Timekeeping::RollbackJournal.new(path: journal_path).resume

  def money_unchanged? = Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process).empty?

  it "runs the whole rollback, reports it, and forgets the journal" do
    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("Timekeeping rollback: close_local at generation 2")
    expect(output).to include(
      "done at generation 2, the prepared application owns entries (reconciled: #{TimesheetEntry.count} entries, 2 reservations, "
    )
    expect(copies).to eq(rolled_back)
    expect(steps_run).to eq(%w[close freeze flip])
    expect(Timekeeping::Entry.find(linked_entry.id).slice(:note, :version)).to eq("note" => "Proofing", "version" => 2)
    expect(Timekeeping::Reservation.all.map { |reservation| reservation.to_value.to_h.values_at(:entry_id, :edit_lock) })
      .to contain_exactly([draft_entry.id, true], [linked_entry.id, false])
    expect(journal_path).not_to exist
    expect(money_unchanged?).to be(true)
  end

  it "resumes in a later invocation, from the journal, a run whose step response was lost" do
    fake.lose_next_response(:run_step)

    output, status = run_task
    expect(status).to eq(1)
    expect(output).to include("stopped: Timekeeping::HandoffClient::Unavailable", "Run bin/rails timekeeping:rollback again to resume")
    expect(copies).to eq([[2, "timekeeping", "closed"], [2, "timekeeping", "closed"]])
    expect(kept.financial_snapshot).to eq(money_before)

    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("freeze_local at generation 2", "done at generation 2")
    expect(output).not_to include("close_local")
    expect(copies).to eq(rolled_back)
    expect(steps_run).to eq(%w[close freeze flip])
    expect(journal_path).not_to exist
    expect(money_unchanged?).to be(true)
  end

  it "checks the money of a resumed run against the snapshot the journal kept, not one of its own" do
    fake.lose_next_response(:run_step)
    expect(run_task.last).to eq(1)
    line = draft.invoice_line_items.first
    recorded = kept.financial_snapshot.deep_dup
    recorded.fetch("invoice_line_items").fetch(line.id.to_s)["rate"] = "1.00"
    Timekeeping::RollbackJournal.new(path: journal_path).record(Timekeeping::Rollback::Resume.new(financial_snapshot: recorded))

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("aborted at reconcile", "  money_differs: invoice_line_items/#{line.id}/rate")
    expect(copies).to eq(aborted)
    expect(journal_path).not_to exist
  end

  it "reports a rollback that is already done, changing nothing" do
    expect(run_task.last).to eq(0)
    calls = fake.calls.size

    output, status = run_task

    expect(status).to eq(0)
    expect(output).to include("done at generation 2, the prepared application owns entries (reconciled earlier)")
    expect(fake.calls.drop(calls).map(&:operation)).to eq(%i[read_handoff])
    expect(copies).to eq(rolled_back)
  end

  it "aborts both copies on a refusal no retry changes, lists what was found, and forgets the journal" do
    fake.fail_next(:take_checkpoint, status: 409, slug: "checkpoint-unsettled", lists: { "provisional_reservation" => [draft_entry.id] })

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("aborted at checkpoint", "  provisional_reservation: #{draft_entry.id}")
    expect(copies).to eq(aborted)
    expect(Timekeeping::Entry.count).to eq(0)
    expect(journal_path).not_to exist
  end

  it "refuses a journal it cannot read, leaving both copies and the file as they are" do
    journal_path.write("{")

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("rollback journal", "cannot be read")
    expect(journal_path.read).to eq("{")
    expect(rollback_calls).to be_empty
    expect(copies).to eq([[1, "timekeeping", "open"], [1, "timekeeping", "open"]])
  end

  it "refuses the first cutover's journal handed to it, leaving both copies and the file as they are" do
    Timekeeping::FirstCutoverJournal.new(path: journal_path).record(Timekeeping::FirstCutover::Resume.new(financial_snapshot: money_before))
    content = journal_path.read

    output, status = run_task

    expect(status).to eq(1)
    expect(output).to include("cannot be read")
    expect(journal_path.read).to eq(content)
    expect(rollback_calls).to be_empty
  end

  describe "timekeeping:rollback:abort" do
    it "reopens admission on both copies of a stopped run under Timekeeping, and forgets the journal" do
      fake.lose_next_response(:run_step)
      expect(run_task.last).to eq(1)
      expect(journal_path).to exist

      output, status = run_task("timekeeping:rollback:abort")

      expect(status).to eq(0)
      expect(output).to include("aborted at generation 2, admission reopened on both copies under Timekeeping")
      expect(copies).to eq(aborted)
      expect(steps_run).to eq(%w[close abort])
      expect(journal_path).not_to exist
    end

    it "refuses when no rollback is in progress, changing nothing" do
      output, status = run_task("timekeeping:rollback:abort")

      expect(status).to eq(1)
      expect(output).to include("nothing to abort")
      expect(copies).to eq([[1, "timekeeping", "open"], [1, "timekeeping", "open"]])
    end
  end
end
