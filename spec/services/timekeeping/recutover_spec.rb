# frozen_string_literal: true

require "rails_helper"

# The handoff tool for the re-cutover (docs/architecture/timekeeping-soa.md
# §10.2 step 6, §10.5): every step in order on this application's copy of the
# ownership record and on Timekeeping's, through its client against the
# consumer-side fake of the handoff API (§12.3), with the checkpoint taken out
# of the prepared application here, loaded into Timekeeping and reconciled on
# both sides.
#
# The state it starts from is reached as the demo journey reaches it: the
# billing states of today's behaviour on two tenants (a direct and a grouped
# draft, a sent invoice discarded after a draft save, a discarded draft,
# tenant B's invoice created sent); the first cutover
# (Timekeeping::FirstCutover) into the fake, whose relay delivers to the real
# projection endpoint; a write Timekeeping takes as the owner, with its audit
# row and receipts; the rollback (Timekeeping::Rollback) that carries all of
# it into the prepared application. The `monolith` owner then takes a create
# on each tenant through the gateway, whose snapshots wait undelivered in the
# local outbox, and the re-cutover must drain them and carry everything back
# to Timekeeping.
RSpec.describe Timekeeping::Recutover, type: :model do
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

  # The money no handoff may move, as it stood before the first one.
  let!(:money_before) { Timekeeping::FinancialSnapshot.process }

  # The projection endpoint verifies the relay's token with the shared key.
  before { allow(Rails.configuration.x.timekeeping).to receive(:token_key).and_return(TimekeepingContracts::TEST_TOKEN_KEY) }

  # The first cutover, Timekeeping's write as the owner, the rollback, then
  # the monolith owner's writes, not yet relayed.
  before do
    quiet = Logger.new(nil)
    Timekeeping::FirstCutover.new(
      client:, unlocked_link_invoice_ids: [unlocked_link_invoice.id], drain: Timekeeping::FirstCutover::Drain.new(pause: relaying), logger: quiet
    ).call

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
    Timekeeping::Rollback.new(client:, drain: Timekeeping::Rollback::Drain.new(pause: relaying), logger: quiet).call

    @written = [log_after_rollback!(tenant_a, duration: 45.5), log_after_rollback!(tenant_b, duration: 0.1)]
    @rollback_calls = fake.calls.size
  end

  after { expect(fake.violations).to be_empty }

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

  def held_entry(entry) = fake.held.fetch("entries").find { |held| held.fetch("id") == entry.id }

  def audit(id:, entry:)
    {
      "id" => id, "entry_id" => entry.id, "company_id" => entry.project.client.company_id, "version" => 2,
      "action" => "update", "actor" => "user:#{entry.user_id}", "agent_id" => nil, "writer" => "web",
      "request_id" => "req-#{id}", "audited_changes" => { "note" => [nil, "Proofing"] }, "created_at" => created_at
    }
  end

  # Timekeeping's relay runs whenever the first cutover or the rollback
  # waits for it.
  def relaying = ->(_seconds) { fake.relay! }

  # The local relay runs whenever the re-cutover waits for it, as its worker
  # would.
  def relaying_locally = ->(_seconds) { Timekeeping::LocalRelay.new.run }

  # One entry the `monolith` owner accepts after the rollback, through the
  # gateway as a controller hands it over: its audit row and its outbox
  # snapshot, and nothing in the projection until the local relay delivers
  # it. Answers the prepared application's entry.
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

  # `resume` is what an earlier run took, handed over in a journal.
  def tool(interrupt_before: nil, drain: described_class::Drain.new(pause: relaying_locally), resume: nil, **options)
    options[:journal] ||= described_class::MemoryJournal.new(resume) if resume
    interruption = interrupted
    logger = Class.new do
      define_method(:info) do |message|
        raise interruption, message if interrupt_before && message.start_with?("Timekeeping re-cutover: #{interrupt_before} at")
      end
    end.new

    described_class.new(client:, drain:, logger:, **options)
  end

  def copies
    local = Timekeeping::Ownership.current
    [[local.generation, local.owner, local.state], fake.copy.to_h.values_at(:generation, :owner, :state)]
  end

  def recutover_calls = fake.calls.drop(@rollback_calls)
  def steps_run = recutover_calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }
  def loads = recutover_calls.count { |call| call.operation == :load_recutover_checkpoint }

  def recut_over = [[3, "timekeeping", "open"], [3, "timekeeping", "open"]]
  def aborted = [[3, "monolith", "open"], [3, "monolith", "open"]]

  def money_unchanged? = Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process).empty?

  def written_ids = @written.map(&:id)

  it "starts from the rollback, with the monolith owner's writes not yet projected" do
    expect(copies).to eq([[2, "monolith", "open"], [2, "monolith", "open"]])
    expect(@written.map(&:company_id)).to eq([tenant_a.company.id, tenant_b.company.id])
    expect(Timekeeping::OutboxSnapshot.undelivered.pluck(:entry_id)).to eq(written_ids)
    expect(TimesheetEntry.where(id: written_ids)).to be_empty
    expect(fake.held.fetch("entries").pluck("id")).not_to include(*written_ids)
  end

  describe "a run from the rolled-back state" do
    it "re-cuts both copies over to Timekeeping at generation 3, and both sides reconcile every part" do
      allow(Timekeeping::HandoffSettle).to receive(:call).and_call_original

      result = tool.call

      expect(Timekeeping::HandoffSettle).to have_received(:call).with(generation: 3).once
      expect(result).to eq(
        described_class::Result.new(
          generation: 3,
          reconciled: Timekeeping::RecutoverReconcile::Reconciled.new(
            entries: TimesheetEntry.count, reservations: 5, entry_audits: 3, reservation_operations: 1, idempotency_receipts: 1
          )
        )
      )
      expect(copies).to eq(recut_over)
      expect(steps_run).to eq(%w[close freeze flip])
      expect(recutover_calls.map(&:operation))
        .to eq(%i[read_handoff run_step run_step load_recutover_checkpoint reconcile_recutover_checkpoint run_step])
    end

    it "drains the monolith owner's writes into the projection before it takes the checkpoint, and carries them to Timekeeping" do
      tool.call

      expect(Timekeeping::OutboxSnapshot.undelivered).to be_empty
      expect(TimesheetEntry.where(id: written_ids).pluck(:duration)).to contain_exactly(45.5, 0.1)
      expect(fake.held.fetch("entries").select { |entry| written_ids.include?(entry.fetch("id")) }.pluck("duration"))
        .to contain_exactly(45.5, 0.1)
    end

    it "carries every entry, reservation, audit row and receipt the prepared application holds, and moves no billing value" do
      tool.call

      expect(fake.held.fetch("entries").pluck("id")).to eq(Timekeeping::Entry.order(:id).ids)
      expect(fake.held.fetch("entries").pluck("id")).to eq(TimesheetEntry.order(:id).ids)
      expect(fake.held.fetch("reservations").map { |row| row.values_at("entry_id", "disposition", "edit_lock") })
        .to contain_exactly(
          [draft_entry.id, "active", true], *grouped_entries.map { |entry| [entry.id, "active", true] },
          [retained_entry.id, "retained", true], [linked_entry.id, "active", false]
        )
      expect(fake.held.fetch("entry_audits").pluck("id")).to eq(Timekeeping::EntryAudit.order(:id).ids)
      expect(fake.held.fetch("entry_audits").pluck("id")).to include(14)
      expect(fake.held.fetch("reservation_operations").pluck("operation_id")).to eq([operation_id])
      expect(fake.held.fetch("idempotency_receipts").map { |row| row.values_at("company_id", "key") }).to eq([[tenant_b.company.id, "web-1"]])
      expect(money_unchanged?).to be(true)
    end

    it "takes the financial snapshot once admission is closed, and keeps it for a resume" do
      recutover = tool
      recutover.call

      expect(recutover.financial_snapshot).to eq(money_before)
      expect(recutover.resume).to eq(described_class::Resume.new(financial_snapshot: money_before))
    end

    it "is done once both copies are re-cut over: a second run changes nothing" do
      tool.call
      calls = fake.calls.size

      expect(tool.call).to eq(described_class::Result.new(generation: 3, reconciled: nil))
      expect(fake.calls.drop(calls).map(&:operation)).to eq(%i[read_handoff])
      expect(copies).to eq(recut_over)
    end
  end

  describe "an interrupted run, resumed" do
    # Where each interruption leaves the two copies: the step before it
    # committed, the one named did not start.
    {
      close_local: [[2, "monolith", "open"], [2, "monolith", "open"]],
      close_remote: [[3, "monolith", "closed"], [2, "monolith", "open"]],
      freeze_local: [[3, "monolith", "closed"], [3, "monolith", "closed"]],
      freeze_remote: [[3, "monolith", "frozen"], [3, "monolith", "closed"]],
      transfer: [[3, "monolith", "frozen"], [3, "monolith", "frozen"]],
      flip_remote: [[3, "monolith", "frozen"], [3, "monolith", "frozen"]],
      flip_local: [[3, "monolith", "frozen"], [3, "timekeeping", "open"]]
    }.each do |step, left|
      it "stops before #{step} with both copies fenced where they were, and resumes to the end running no step twice" do
        stopped = tool(interrupt_before: step)
        expect { stopped.call }.to raise_error(interrupted)
        expect(copies).to eq(left)

        expect(tool(resume: stopped.resume).call.generation).to eq(3)
        expect(copies).to eq(recut_over)
        expect(steps_run).to eq(%w[close freeze flip])
        expect(fake.held.fetch("entries").pluck("id")).to include(*written_ids)
        expect(money_unchanged?).to be(true)
      end
    end

    it "takes the checkpoint again on a resumed transfer, and loading it again leaves Timekeeping holding the same" do
      expect { tool(interrupt_before: :flip_remote).call }.to raise_error(interrupted)
      held = fake.held

      result = tool.call

      expect(result.reconciled.entries).to eq(TimesheetEntry.count)
      expect(loads).to eq(2)
      expect(fake.held).to eq(held)
      expect(copies).to eq(recut_over)
    end

    it "sends the load again when its response was lost" do
      fake.lose_next_response(:load_recutover_checkpoint)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      expect(copies).to eq([[3, "monolith", "frozen"], [3, "monolith", "frozen"]])

      tool.call

      expect(loads).to eq(2)
      expect(copies).to eq(recut_over)
    end

    it "resumes a Timekeeping step whose response was lost, from where the step left its copy" do
      fake.lose_next_response(:run_step)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      expect(copies).to eq([[3, "monolith", "closed"], [3, "monolith", "closed"]])

      tool.call

      expect(copies).to eq(recut_over)
      expect(steps_run).to eq(%w[close freeze flip])
    end

    it "stops with both copies frozen, carrying nothing, when the local relay does not drain in time, and resumes once it runs" do
      now = 0
      stalled = tool(drain: described_class::Drain.new(timeout: 5, pause: ->(seconds) { now += seconds }, clock: -> { now }))

      expect { stalled.call }.to raise_error(described_class::DrainTimeout, /2 snapshots undelivered after 5 s/)
      expect(copies).to eq([[3, "monolith", "frozen"], [3, "monolith", "frozen"]])
      expect(loads).to eq(0)

      tool(resume: stalled.resume).call
      expect(copies).to eq(recut_over)
    end

    it "stops, fenced, when Timekeeping's close waits out the calls it already admitted, and resumes" do
      fake.fail_next(:run_step, status: 503, slug: "drain-timeout", retryable: true)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem, /drain-timeout/)
      expect(copies).to eq([[3, "monolith", "closed"], [2, "monolith", "open"]])

      tool.call
      expect(copies).to eq(recut_over)
    end

    it "leaves both copies frozen for a resume when the reconcile is refused retryably" do
      fake.fail_next(:reconcile_recutover_checkpoint, status: 503, slug: "drain-timeout", retryable: true)

      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem)
      expect(copies).to eq([[3, "monolith", "frozen"], [3, "monolith", "frozen"]])

      tool.call
      expect(copies).to eq(recut_over)
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
      expect(copies).to eq(recut_over)
    end

    it "is told the snapshot a resumed transfer takes when the run that closed admission left none" do
      expect { tool(interrupt_before: :close_remote).call }.to raise_error(interrupted)

      journal = journal_of
      tool(journal:).call

      expect(journal.records).to eq([described_class::Resume.new(financial_snapshot: money_before)])
    end

    it "checks money against the snapshot the journal holds, not one the resumed run takes" do
      stopped = tool(interrupt_before: :transfer)
      expect { stopped.call }.to raise_error(interrupted)
      line = draft.invoice_line_items.first
      kept = stopped.financial_snapshot.deep_dup
      kept.fetch("invoice_line_items").fetch(line.id.to_s)["rate"] = "101.0"

      failure = nil
      expect { tool(resume: described_class::Resume.new(financial_snapshot: kept)).call }
        .to raise_error(described_class::Aborted) { |error| failure = error }

      expect(failure.step).to eq(:reconcile_local)
      expect(failure.lists.fetch(:money_differs)).to include("invoice_line_items/#{line.id}/rate")
    end
  end

  describe "a refusal no retry changes aborts the handoff on both copies" do
    def aborted_at(recutover = tool)
      failure = nil
      expect { recutover.call }.to raise_error(described_class::Aborted) { |error| failure = error }
      expect(copies).to eq(aborted)
      failure
    end

    it "aborts when the prepared application holds an operation settle left unresolved, carrying nothing" do
      allow(Timekeeping::LocalCheckpoint).to receive(:take)
        .and_raise(Timekeeping::LocalCheckpoint::Unsettled.new(provisional_reservation: [draft_entry.id]))

      failure = aborted_at

      expect(failure.step).to eq(:checkpoint)
      expect(failure.lists).to eq(provisional_reservation: [draft_entry.id])
      expect(loads).to eq(0)
    end

    it "aborts when Timekeeping refuses the checkpoint" do
      fake.fail_next(:load_recutover_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "entry_behind" => [linked_entry.id] })

      failure = aborted_at

      expect(failure.step).to eq(:load)
      expect(failure.lists).to eq("entry_behind" => [linked_entry.id])
      expect(recutover_calls.map(&:operation)).not_to include(:reconcile_recutover_checkpoint)
    end

    it "aborts when Timekeeping's reconcile finds what it holds differs from the checkpoint" do
      fake.fail_next(:reconcile_recutover_checkpoint, status: 409, slug: "checkpoint-differs", lists: { "entry_differs" => [draft_entry.id] })

      failure = aborted_at

      expect(failure.step).to eq(:reconcile_remote)
      expect(failure.lists).to eq("entry_differs" => [draft_entry.id])
    end

    it "aborts when this side's reconcile finds a billing value moved during the handoff" do
      line = draft.invoice_line_items.first
      moving = ->(_seconds) {
        Timekeeping::LocalRelay.new.run
        InvoiceLineItem.where(id: line.id).update_all(rate: 101) # a write no fence sees
      }

      failure = aborted_at(tool(drain: described_class::Drain.new(pause: moving)))

      expect(failure.step).to eq(:reconcile_local)
      expect(failure.lists.keys).to eq([:money_differs])
      expect(failure.lists.fetch(:money_differs)).to include("invoice_line_items/#{line.id}/rate")
    end

    it "aborts when the two sides count the checkpoint's parts differently" do
      allow(client).to receive(:reconcile_recutover_checkpoint).and_wrap_original do |original, checkpoint|
        original.call(checkpoint).with(entry_audits: 0)
      end

      failure = aborted_at

      expect(failure.step).to eq(:reconcile)
      expect(failure.lists).to eq(receipt_differs: ["entry_audits"])
      expect(failure.message).to match(/entry_audits.*0.*entry_audits.*3/)
    end

    it "keeps the raised generation, so commands admitted under the old one stay refused" do
      fake.fail_next(:load_recutover_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "entry_behind" => [linked_entry.id] })
      aborted_at

      expect(Timekeeping::Ownership.current.generation).to eq(3)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "re-cuts over after an aborted re-cutover, carrying what the monolith owner wrote since over the earlier load" do
      expect { tool(interrupt_before: :flip_remote).call }.to raise_error(interrupted)
      tool.abort!
      later = log_after_rollback!(tenant_a, duration: 12.25)

      expect(tool.call.generation).to eq(4)

      expect(copies).to eq([[4, "timekeeping", "open"], [4, "timekeeping", "open"]])
      expect(fake.held.fetch("entries").find { |entry| entry.fetch("id") == later.id }.fetch("duration")).to eq(12.25)
      expect(fake.held.fetch("entries").pluck("id")).to eq(TimesheetEntry.order(:id).ids)
    end
  end

  describe "#abort!" do
    it "reopens admission on both copies at the raised generation, under the monolith owner" do
      expect { tool(interrupt_before: :transfer).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(3)
      expect(copies).to eq(aborted)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "reopens only this copy when Timekeeping's was never closed" do
      expect { tool(interrupt_before: :close_remote).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(3)
      expect(copies).to eq([[3, "monolith", "open"], [2, "monolith", "open"]])
      expect(steps_run).to be_empty
    end

    it "refuses when no re-cutover is in progress, changing nothing" do
      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[2, "monolith", "open"], [2, "monolith", "open"]])
    end

    it "refuses once Timekeeping's copy has flipped: past the flip the handoff only goes forward" do
      expect { tool(interrupt_before: :flip_local).call }.to raise_error(interrupted)

      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[3, "monolith", "frozen"], [3, "timekeeping", "open"]])
    end
  end

  describe "copies no step of the re-cutover leaves" do
    {
      "the first cutover still frozen" => [{ generation: 1, owner: "legacy", state: "frozen" }, { generation: 1, owner: "legacy", state: "frozen" }],
      "a rollback under way" => [{ generation: 2, owner: "timekeeping", state: "frozen" }, { generation: 2, owner: "timekeeping", state: "frozen" }],
      "Timekeeping's copy ahead of this one" => [{ generation: 2, owner: "monolith", state: "open" }, { generation: 3, owner: "monolith", state: "closed" }],
      "the two copies at different generations" => [{ generation: 4, owner: "monolith", state: "open" }, { generation: 2, owner: "monolith", state: "open" }],
      "this copy frozen and Timekeeping's reopened by an abort" => [{ generation: 3, owner: "monolith", state: "frozen" }, { generation: 3, owner: "monolith", state: "open" }],
      "this copy flipped before Timekeeping's" => [{ generation: 3, owner: "timekeeping", state: "open" }, { generation: 3, owner: "monolith", state: "frozen" }]
    }.each do |name, (local, remote)|
      it "refuses with #{name}, changing nothing" do
        set_timekeeping_ownership!(local)
        other = TimekeepingContracts::FakeHandoff.new(**remote).install!

        expect { tool.call }.to raise_error(described_class::Unresumable, /no step of the re-cutover leaves/)
        expect(other.calls.map(&:operation)).to eq(%i[read_handoff])
        expect(Timekeeping::Ownership.current.slice(:generation, :owner, :state).symbolize_keys).to eq(local)
      end
    end
  end
end
