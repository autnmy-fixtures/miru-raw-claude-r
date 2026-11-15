# frozen_string_literal: true

require "rails_helper"

# The handoff tool for the rollback (docs/architecture/timekeeping-soa.md
# §10.2 step 6, §10.5): every step in order on this application's copy of the
# ownership record and on Timekeeping's, through its client against the
# consumer-side fake of the handoff API (§12.3), with the checkpoint taken out
# of Timekeeping loaded and reconciled in the prepared application here.
#
# The state it starts from is reached as the demo reaches it: the billing
# states of today's behaviour on two tenants (a direct and a grouped draft, a
# sent invoice discarded after a draft save, a discarded draft, tenant B's
# invoice created sent), then the first cutover (Timekeeping::FirstCutover)
# into the fake, whose relay delivers to the real projection endpoint. After
# that Timekeeping takes a write as the owner, with its audit row and its
# receipts, and the rollback must carry all of it back.
RSpec.describe Timekeeping::Rollback, type: :model do
  include_context "with two Timekeeping tenants"

  # Raised by the logger to interrupt a run just before a step.
  let(:interrupted) { Class.new(StandardError) }

  let!(:fake) { TimekeepingContracts::FakeHandoff.new.install! }
  let(:client) { Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 90.7) }
  let!(:grouped_entries) { [unbilled_entry(tenant_a, duration: 0.1), unbilled_entry(tenant_a, duration: 479.99999)] }
  let!(:retained_entry) { unbilled_entry(tenant_a) }
  let!(:released_entry) { unbilled_entry(tenant_a) }
  let!(:linked_entry) { unbilled_entry(tenant_b) }

  let!(:draft) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, draft_entry)
      grouped_line(invoice, grouped_entries)
      invoice.reload.save!
    end
  end
  let!(:retained_invoice) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, retained_entry)
      invoice.reload.save!
      invoice.update!(status: :sent)
      invoice.discard!
    end
  end
  let!(:discarded_draft) do
    invoice_for(tenant_a).tap do |invoice|
      direct_line(invoice, released_entry)
      invoice.reload.save!
      invoice.discard!
    end
  end
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  let(:created_at) { "2026-11-02T09:15:30.123456Z" }
  let(:operation_id) { "3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f" }

  # The projection endpoint verifies the relay's token with the shared key.
  before { allow(Rails.configuration.x.timekeeping).to receive(:token_key).and_return(TimekeepingContracts::TEST_TOKEN_KEY) }

  # The first cutover, then Timekeeping's write as the owner.
  before do
    Timekeeping::FirstCutover.new(
      client:, unlocked_link_invoice_ids: [unlocked_link_invoice.id], drain: Timekeeping::FirstCutover::Drain.new(pause: relaying), logger: Logger.new(nil)
    ).call
    @cutover_calls = fake.calls.size

    fake.write!(held_entry(linked_entry).merge("note" => "Proofing", "version" => 2))
    fake.hold!(
      entry_audits: [audit(id: 14, entry: linked_entry)],
      reservation_operations: [
        { "invoice_id" => draft.id, "operation_id" => operation_id, "company_id" => tenant_a.company.id, "kind" => "save",
          "invoice_state" => "draft", "entry_ids" => [draft_entry.id, *grouped_entries.map(&:id)], "state" => "committed",
          "created_at" => created_at, "updated_at" => created_at }
      ],
      idempotency_receipts: [
        { "company_id" => tenant_b.company.id, "key" => "web-1", "request_digest" => "d1", "status" => 200,
          "response" => { "entry" => { "id" => linked_entry.id, "note" => "Proofing" } }, "created_at" => created_at }
      ]
    )
  end

  # The money no handoff may move, as it stood once the cutover was done.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  after { expect(fake.violations).to be_empty }

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

  def held_entry(entry) = fake.held.fetch("entries").find { |held| held.fetch("id") == entry.id }

  def audit(id:, entry:)
    {
      "id" => id, "entry_id" => entry.id, "company_id" => entry.project.client.company_id, "version" => 2,
      "action" => "update", "actor" => "user:#{entry.user_id}", "agent_id" => nil, "writer" => "web",
      "request_id" => "req-#{id}", "audited_changes" => { "note" => [nil, "Proofing"] }, "created_at" => created_at
    }
  end

  # The relay runs whenever the tool waits for it.
  def relaying = ->(_seconds) { fake.relay! }

  # `resume` is what an earlier run took, handed over in a journal.
  def tool(interrupt_before: nil, drain: described_class::Drain.new(pause: relaying), resume: nil, **options)
    options[:journal] ||= described_class::MemoryJournal.new(resume) if resume
    interruption = interrupted
    logger = Class.new do
      define_method(:info) do |message|
        raise interruption, message if interrupt_before && message.start_with?("Timekeeping rollback: #{interrupt_before} at")
      end
    end.new

    described_class.new(client:, drain:, logger:, **options)
  end

  def copies
    local = Timekeeping::Ownership.current
    [[local.generation, local.owner, local.state], fake.copy.to_h.values_at(:generation, :owner, :state)]
  end

  def rollback_calls = fake.calls.drop(@cutover_calls)
  def steps_run = rollback_calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }

  def rolled_back = [[2, "monolith", "open"], [2, "monolith", "open"]]
  def aborted = [[2, "timekeeping", "open"], [2, "timekeeping", "open"]]

  def money_unchanged? = Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process).empty?

  it "starts from the first cutover, with Timekeeping's write not yet projected" do
    expect(copies).to eq([[1, "timekeeping", "open"], [1, "timekeeping", "open"]])
    expect(fake.undelivered.map { |snapshot| snapshot.values_at("entry_id", "version") }).to eq([[linked_entry.id, 2]])
    expect(Timekeeping::Entry.count).to eq(0)
  end

  describe "a run from the cut-over state" do
    it "rolls both copies back to the prepared application at generation 2, and reconciles every part" do
      allow(Timekeeping::HandoffSettle).to receive(:call).and_call_original

      result = tool.call

      expect(Timekeeping::HandoffSettle).to have_received(:call).with(generation: 2).once
      expect(result).to eq(
        described_class::Result.new(
          generation: 2,
          reconciled: Timekeeping::RollbackReconcile::Reconciled.new(
            entries: TimesheetEntry.count, reservations: 5, entry_audits: 1, reservation_operations: 1, idempotency_receipts: 1
          )
        )
      )
      expect(copies).to eq(rolled_back)
      expect(steps_run).to eq(%w[close freeze flip])
      expect(rollback_calls.map(&:operation))
        .to eq(%i[read_handoff run_step run_step read_handoff read_handoff take_checkpoint run_step])
    end

    it "drains Timekeeping's write into the projection before it takes the checkpoint, and carries it into the prepared tables" do
      tool.call

      expect(fake.undelivered).to be_empty
      expect(TimesheetEntry.find(linked_entry.id).slice(:note, :version)).to eq("note" => "Proofing", "version" => 2)
      expect(Timekeeping::Entry.find(linked_entry.id).slice(:note, :version)).to eq("note" => "Proofing", "version" => 2)
    end

    it "loads every entry, reservation, audit row and receipt as Timekeeping held them, and moves no billing value" do
      tool.call

      expect(Timekeeping::Entry.order(:id).ids).to eq(TimesheetEntry.order(:id).ids)
      expect(Timekeeping::Entry.where(id: draft_entry.id).pick(:duration)).to eq(90.7)
      expect(Timekeeping::Reservation.all.map { |reservation| reservation.to_value.to_h.values_at(:entry_id, :disposition, :edit_lock) })
        .to contain_exactly(
          [draft_entry.id, :active, true], *grouped_entries.map { |entry| [entry.id, :active, true] },
          [retained_entry.id, :retained, true], [linked_entry.id, :active, false]
        )
      expect(Timekeeping::EntryAudit.ids).to eq([14])
      expect(Timekeeping::ReservationOperation.pluck(:operation_id)).to eq([operation_id])
      expect(Timekeeping::IdempotencyReceipt.pluck(:company_id, :key)).to eq([[tenant_b.company.id, "web-1"]])
      expect(money_unchanged?).to be(true)
    end

    it "takes the financial snapshot once admission is closed, and keeps it for a resume" do
      rollback = tool
      rollback.call

      expect(rollback.financial_snapshot).to eq(money_before)
      expect(rollback.resume).to eq(described_class::Resume.new(financial_snapshot: money_before))
    end

    it "is done once both copies are rolled back: a second run changes nothing" do
      tool.call
      calls = fake.calls.size

      expect(tool.call).to eq(described_class::Result.new(generation: 2, reconciled: nil))
      expect(fake.calls.drop(calls).map(&:operation)).to eq(%i[read_handoff])
      expect(copies).to eq(rolled_back)
    end
  end

  describe "an interrupted run, resumed" do
    # Where each interruption leaves the two copies: the step before it
    # committed, the one named did not start.
    {
      close_local: [[1, "timekeeping", "open"], [1, "timekeeping", "open"]],
      close_remote: [[2, "timekeeping", "closed"], [1, "timekeeping", "open"]],
      freeze_local: [[2, "timekeeping", "closed"], [2, "timekeeping", "closed"]],
      freeze_remote: [[2, "timekeeping", "frozen"], [2, "timekeeping", "closed"]],
      transfer: [[2, "timekeeping", "frozen"], [2, "timekeeping", "frozen"]],
      flip_local: [[2, "timekeeping", "frozen"], [2, "timekeeping", "frozen"]],
      flip_remote: [[2, "monolith", "open"], [2, "timekeeping", "frozen"]]
    }.each do |step, left|
      it "stops before #{step} with both copies fenced where they were, and resumes to the end running no step twice" do
        stopped = tool(interrupt_before: step)
        expect { stopped.call }.to raise_error(interrupted)
        expect(copies).to eq(left)

        expect(tool(resume: stopped.resume).call.generation).to eq(2)
        expect(copies).to eq(rolled_back)
        expect(steps_run).to eq(%w[close freeze flip])
        expect(Timekeeping::Entry.find(linked_entry.id).note).to eq("Proofing")
        expect(money_unchanged?).to be(true)
      end
    end

    it "reconciles a load that already ran against Timekeeping as it stands, taking the checkpoint again" do
      expect { tool(interrupt_before: :flip_local).call }.to raise_error(interrupted)
      expect(Timekeeping::Entry.count).to eq(TimesheetEntry.count)

      result = tool.call

      expect(result.reconciled.entries).to eq(TimesheetEntry.count)
      expect(rollback_calls.count { |call| call.operation == :take_checkpoint }).to eq(2)
      expect(copies).to eq(rolled_back)
    end

    it "resumes a Timekeeping step whose response was lost, from where the step left its copy" do
      fake.lose_next_response(:run_step)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      expect(copies).to eq([[2, "timekeeping", "closed"], [2, "timekeeping", "closed"]])

      tool.call

      expect(copies).to eq(rolled_back)
      expect(steps_run).to eq(%w[close freeze flip])
    end

    it "stops with both copies frozen, loading nothing, when the relay does not drain in time, and resumes once it runs" do
      now = 0
      stalled = tool(drain: described_class::Drain.new(timeout: 5, pause: ->(seconds) { now += seconds }, clock: -> { now }))

      expect { stalled.call }.to raise_error(described_class::DrainTimeout, /1 snapshots undelivered after 5 s/)
      expect(copies).to eq([[2, "timekeeping", "frozen"], [2, "timekeeping", "frozen"]])
      expect(rollback_calls.map(&:operation)).not_to include(:take_checkpoint)
      expect(Timekeeping::Entry.count).to eq(0)

      tool(resume: stalled.resume).call
      expect(copies).to eq(rolled_back)
    end

    it "stops, fenced, when Timekeeping's close waits out the calls it already admitted, and resumes" do
      fake.fail_next(:run_step, status: 503, slug: "drain-timeout", retryable: true)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem, /drain-timeout/)
      expect(copies).to eq([[2, "timekeeping", "closed"], [1, "timekeeping", "open"]])

      tool.call
      expect(copies).to eq(rolled_back)
    end

    it "leaves both copies frozen for a resume when the take is refused retryably" do
      fake.fail_next(:take_checkpoint, status: 503, slug: "drain-timeout", retryable: true)

      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem)
      expect(copies).to eq([[2, "timekeeping", "frozen"], [2, "timekeeping", "frozen"]])
    end
  end

  describe "the journal" do
    # Records each resume it is told.
    def journal_of(resume = described_class::Resume.new)
      Class.new(described_class::MemoryJournal) do
        define_method(:records) { @records ||= [] }
        define_method(:record) do |taken|
          records << taken
          super(taken)
        end
      end.new(resume)
    end

    it "is told an empty resume as the handoff starts, then the financial snapshot" do
      journal = journal_of(described_class::Resume.new(financial_snapshot: { "invoices" => {} }))
      tool(journal:).call

      expect(journal.records).to eq([described_class::Resume.new, described_class::Resume.new(financial_snapshot: money_before)])
    end

    it "starts the run from what the journal holds, and tells it nothing new when that holds the snapshot" do
      stopped = tool(interrupt_before: :transfer)
      expect { stopped.call }.to raise_error(interrupted)

      journal = journal_of(stopped.resume)
      tool(journal:).call

      expect(journal.records).to be_empty
      expect(copies).to eq(rolled_back)
    end

    it "is told the snapshot a resumed transfer takes when the run that closed admission left none" do
      expect { tool(interrupt_before: :close_remote).call }.to raise_error(interrupted)

      journal = journal_of
      tool(journal:).call

      expect(journal.records).to eq([described_class::Resume.new(financial_snapshot: money_before)])
    end
  end

  describe "a refusal no retry changes aborts the handoff on both copies" do
    def aborted_at(rollback = tool)
      failure = nil
      expect { rollback.call }.to raise_error(described_class::Aborted) { |error| failure = error }
      expect(copies).to eq(aborted)
      failure
    end

    it "aborts when Timekeeping holds an operation settle left unresolved, loading nothing" do
      fake.fail_next(:take_checkpoint, status: 409, slug: "checkpoint-unsettled", lists: { "provisional_reservation" => [draft_entry.id] })

      failure = aborted_at

      expect(failure.step).to eq(:checkpoint)
      expect(failure.lists).to eq("provisional_reservation" => [draft_entry.id])
      expect(Timekeeping::Entry.count).to eq(0)
    end

    it "aborts when the prepared application refuses the checkpoint, loading nothing" do
      fake.write!(held_entry(retained_entry).merge("locked" => false, "version" => 2))

      failure = aborted_at

      expect(failure.step).to eq(:load)
      expect(failure.lists).to eq(locked_not_derived: [retained_entry.id])
      expect(Timekeeping::Entry.count).to eq(0)
    end

    it "aborts when the reconcile finds a billing value moved during the handoff" do
      line = draft.invoice_line_items.first
      moving = ->(_seconds) {
        fake.relay!
        InvoiceLineItem.where(id: line.id).update_all(rate: 101) # a write no fence sees
      }

      failure = aborted_at(tool(drain: described_class::Drain.new(pause: moving)))

      expect(failure.step).to eq(:reconcile)
      expect(failure.lists.keys).to eq([:money_differs])
      expect(failure.lists.fetch(:money_differs)).to include("invoice_line_items/#{line.id}/rate")
    end

    it "keeps the raised generation, so commands admitted under the old one stay refused" do
      fake.fail_next(:take_checkpoint, status: 409, slug: "checkpoint-unsettled", lists: { "provisional_reservation" => [draft_entry.id] })
      aborted_at

      expect(Timekeeping::Ownership.current.generation).to eq(2)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "never flips onto a load an aborted rollback left: the next rollback reconciles it and aborts on Timekeeping's later write" do
      expect { tool(interrupt_before: :flip_local).call }.to raise_error(interrupted)
      tool.abort!
      fake.write!(held_entry(draft_entry).merge("note" => "Later", "version" => 2))

      failure = nil
      expect { tool.call }.to raise_error(described_class::Aborted) { |error| failure = error }

      expect(failure.step).to eq(:reconcile)
      expect(failure.lists).to include(entry_differs: [draft_entry.id])
      expect(copies).to eq([[3, "timekeeping", "open"], [3, "timekeeping", "open"]])
    end
  end

  describe "#abort!" do
    it "reopens admission on both copies at the raised generation, under Timekeeping" do
      expect { tool(interrupt_before: :transfer).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(2)
      expect(copies).to eq(aborted)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "reopens only this copy when Timekeeping's was never closed" do
      expect { tool(interrupt_before: :close_remote).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(2)
      expect(copies).to eq([[2, "timekeeping", "open"], [1, "timekeeping", "open"]])
      expect(steps_run).to be_empty
    end

    it "refuses when no rollback is in progress, changing nothing" do
      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[1, "timekeeping", "open"], [1, "timekeeping", "open"]])
    end

    it "refuses once this copy has flipped: past the flip the handoff only goes forward" do
      expect { tool(interrupt_before: :flip_remote).call }.to raise_error(interrupted)

      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[2, "monolith", "open"], [2, "timekeeping", "frozen"]])
    end
  end

  describe "copies no step of the rollback leaves" do
    {
      "the first cutover still frozen" => [{ generation: 1, owner: "legacy", state: "frozen" }, { generation: 1, owner: "legacy", state: "frozen" }],
      "Timekeeping's copy ahead of this one" => [{ generation: 1, owner: "timekeeping", state: "open" }, { generation: 2, owner: "timekeeping", state: "closed" }],
      "the two copies at different generations" => [{ generation: 3, owner: "timekeeping", state: "open" }, { generation: 1, owner: "timekeeping", state: "open" }],
      "this copy frozen and Timekeeping's reopened by an abort" => [{ generation: 2, owner: "timekeeping", state: "frozen" }, { generation: 2, owner: "timekeeping", state: "open" }],
      "a re-cutover under way" => [{ generation: 3, owner: "monolith", state: "frozen" }, { generation: 3, owner: "monolith", state: "frozen" }]
    }.each do |name, (local, remote)|
      it "refuses with #{name}, changing nothing" do
        set_timekeeping_ownership!(local)
        other = TimekeepingContracts::FakeHandoff.new(**remote).install!

        expect { tool.call }.to raise_error(described_class::Unresumable, /no step of the rollback leaves/)
        expect(other.calls.map(&:operation)).to eq(%i[read_handoff])
        expect(Timekeeping::Ownership.current.slice(:generation, :owner, :state).symbolize_keys).to eq(local)
      end
    end
  end
end
