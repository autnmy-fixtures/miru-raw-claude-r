# frozen_string_literal: true

require "rails_helper"

# The handoff tool for the first cutover (docs/architecture/timekeeping-soa.md
# §10.2 step 5, §10.5): every step in order on this application's copy of the
# ownership record and on Timekeeping's, through its client against the
# consumer-side fake of the handoff API (§12.3). The fake's relay delivers the
# load's snapshots to the real projection endpoint, so this application's
# reconcile runs on the projection as the relay leaves it.
#
# Each billing state is reached through today's behaviour before the handoff
# starts, on two tenants: a direct and a grouped draft (L1), a sent invoice
# discarded after a draft save (L3, retained), a discarded draft (F2,
# released), and tenant B's invoice created sent, an unlocked link with its
# recorded disposition.
RSpec.describe Timekeeping::FirstCutover, type: :model do
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

  let!(:money_before) { Timekeeping::FinancialSnapshot.process }
  let!(:projection_before) { TimesheetEntry.order(:id).pluck(:id, :locked, :version) }

  # The projection endpoint verifies the relay's token with the shared key.
  before { allow(Rails.configuration.x.timekeeping).to receive(:token_key).and_return(TimekeepingContracts::TEST_TOKEN_KEY) }

  after { expect(fake.violations).to be_empty }

  # The relay runs whenever the tool waits for it.
  def relaying = ->(_seconds) { fake.relay! }

  def tool(interrupt_before: nil, pause: relaying, **options)
    interruption = interrupted
    logger = Class.new do
      define_method(:info) do |message|
        raise interruption, message if interrupt_before && message.start_with?("Timekeeping first cutover: #{interrupt_before} at")
      end
    end.new

    described_class.new(client:, unlocked_link_invoice_ids: [unlocked_link_invoice.id], pause:, logger:, **options)
  end

  def copies
    local = Timekeeping::Ownership.current
    [[local.generation, local.owner, local.state], fake.copy.to_h.values_at(:generation, :owner, :state)]
  end

  def steps_run = fake.calls.filter_map { |call| call.params.fetch("step") if call.operation == :run_step }

  def cut_over = [[1, "timekeeping", "open"], [1, "timekeeping", "open"]]
  def aborted = [[1, "legacy", "open"], [1, "legacy", "open"]]

  describe "a run from the initial legacy state" do
    it "cuts both copies over to Timekeeping at generation 1, and reconciles every entry and reservation" do
      allow(Timekeeping::HandoffSettle).to receive(:call).and_call_original

      result = tool.call

      expect(Timekeeping::HandoffSettle).to have_received(:call).with(generation: 1).once

      expect(result).to eq(described_class::Result.new(generation: 1, entries: TimesheetEntry.count, reservations: 5))
      expect(copies).to eq(cut_over)
      expect(steps_run).to eq(%w[close freeze flip])
      expect(fake.calls.map(&:operation))
        .to eq(%i[read_handoff run_step run_step read_handoff load_checkpoint read_handoff read_handoff reconcile_checkpoint run_step])
    end

    it "loads every entry and its reservation into Timekeeping, values as stored" do
      tool(request_id: "handoff-1").call

      loaded = fake.loaded
      expect(loaded.fetch("entries").map { |entry| entry.fetch("id") }).to eq(TimesheetEntry.order(:id).ids)
      expect(loaded.fetch("entries").map { |entry| entry.fetch("duration") }).to include(90.7, 0.1, 479.99999)
      expect(loaded.fetch("reservations").map { |reservation| reservation.values_at("entry_id", "disposition", "edit_lock") })
        .to contain_exactly(
          [draft_entry.id, "active", true], *grouped_entries.map { |entry| [entry.id, "active", true] },
          [retained_entry.id, "retained", true], [linked_entry.id, "active", false]
        )
      expect(fake.calls.find { |call| call.operation == :load_checkpoint }.request_id).to eq("handoff-1")
    end

    it "leaves the projection at Timekeeping's first version of every entry, with the F2 release, and no billing value moved" do
      tool.call

      expect(TimesheetEntry.order(:id).pluck(:id, :version).map(&:last).uniq).to eq([1])
      expect(TimesheetEntry.order(:id).pluck(:id, :locked))
        .to eq(projection_before.map { |id, locked, _| [id, id == released_entry.id ? false : locked] })
      expect(locked?(released_entry)).to be(false)
      expect(Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process)).to be_empty
    end

    it "takes the financial snapshot once admission is closed, and keeps it for a resume" do
      cutover = tool
      cutover.call

      expect(cutover.financial_snapshot).to eq(money_before)
      expect(JSON.parse(JSON.generate(cutover.financial_snapshot))).to eq(money_before)
    end

    it "is done once both copies are cut over: a second run changes nothing" do
      tool.call
      calls = fake.calls.size

      expect(tool.call).to eq(described_class::Result.new(generation: 1, entries: nil, reservations: nil))
      expect(fake.calls.drop(calls).map(&:operation)).to eq(%i[read_handoff])
      expect(copies).to eq(cut_over)
    end
  end

  describe "an interrupted run, resumed" do
    # Where each interruption leaves the two copies: the step before it
    # committed, the one named did not start.
    {
      close_local: [[0, "legacy", "open"], [0, "legacy", "open"]],
      close_remote: [[1, "legacy", "closed"], [0, "legacy", "open"]],
      freeze_local: [[1, "legacy", "closed"], [1, "legacy", "closed"]],
      freeze_remote: [[1, "legacy", "frozen"], [1, "legacy", "closed"]],
      transfer: [[1, "legacy", "frozen"], [1, "legacy", "frozen"]],
      flip_remote: [[1, "legacy", "frozen"], [1, "legacy", "frozen"]],
      flip_local: [[1, "legacy", "frozen"], [1, "timekeeping", "open"]]
    }.each do |step, left|
      it "stops before #{step} with both copies fenced where they were, and resumes to the end running no step twice" do
        stopped = tool(interrupt_before: step)
        expect { stopped.call }.to raise_error(interrupted)
        expect(copies).to eq(left)

        result = tool(financial_snapshot: stopped.financial_snapshot, checkpoint: stopped.checkpoint).call

        expect(result.generation).to eq(1)
        expect(copies).to eq(cut_over)
        expect(steps_run).to eq(%w[close freeze flip])
        expect(Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process)).to be_empty
      end
    end

    it "resumes a load whose response was lost: Timekeeping answers already-loaded, and the run reconciles the same checkpoint" do
      fake.lose_next_response(:load_checkpoint)
      cutover = tool
      expect { cutover.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      expect(fake.loaded).to be_present
      fake.relay! # the relay keeps running while the run is stopped

      expect(cutover.call).to eq(described_class::Result.new(generation: 1, entries: TimesheetEntry.count, reservations: 5))
      expect(fake.calls.count { |call| call.operation == :load_checkpoint }).to eq(2)
      expect(copies).to eq(cut_over)
    end

    it "refuses to take a second checkpoint once the load has run, changing nothing" do
      fake.lose_next_response(:load_checkpoint)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      fake.relay!

      expect { tool.call }.to raise_error(described_class::Unresumable, /already loaded .*resume with the checkpoint taken before the load/)
      expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
      expect(fake.calls.count { |call| call.operation == :load_checkpoint }).to eq(1)
    end

    it "resumes a Timekeeping step whose response was lost, from where the step left its copy" do
      fake.lose_next_response(:run_step)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Unavailable)
      expect(copies).to eq([[1, "legacy", "closed"], [1, "legacy", "closed"]])

      tool.call

      expect(copies).to eq(cut_over)
      expect(steps_run).to eq(%w[close freeze flip])
    end

    it "refuses a checkpoint taken at another generation, changing nothing" do
      expect { tool(interrupt_before: :transfer).call }.to raise_error(interrupted)
      other = Timekeeping::LegacyCheckpoint::Checkpoint.new(generation: 2, entries: [], reservations: [])

      expect { tool(checkpoint: other).call }.to raise_error(described_class::Unresumable, /taken at generation 2, the handoff is at 1/)
      expect(fake.loaded).to be_nil
      expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
    end

    it "stops with both copies frozen when the relay does not drain in time, and resumes once it runs" do
      now = 0
      stalled = tool(pause: ->(seconds) { now += seconds }, clock: -> { now }, drain_timeout: 5)

      expect { stalled.call }.to raise_error(described_class::DrainTimeout, /\d+ snapshots undelivered after 5 s/)
      expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
      expect(fake.undelivered).not_to be_empty

      tool(financial_snapshot: stalled.financial_snapshot, checkpoint: stalled.checkpoint).call
      expect(copies).to eq(cut_over)
    end

    it "stops, fenced, when Timekeeping's close waits out the calls it already admitted, and resumes" do
      fake.fail_next(:run_step, status: 503, slug: "drain-timeout", retryable: true)
      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem, /drain-timeout/)
      expect(copies).to eq([[1, "legacy", "closed"], [0, "legacy", "open"]])

      tool.call
      expect(copies).to eq(cut_over)
    end
  end

  describe "a refusal no retry changes aborts the handoff on both copies" do
    def aborted_at(cutover = tool)
      failure = nil
      expect { cutover.call }.to raise_error(described_class::Aborted) { |error| failure = error }
      expect(copies).to eq(aborted)
      failure
    end

    it "aborts when the pre-flight lists an unlocked link with no recorded disposition, loading nothing" do
      failure = aborted_at(described_class.new(client:, pause: relaying, logger: Logger.new(nil)))

      expect(failure.step).to eq(:checkpoint)
      expect(failure.lists).to eq(unlocked_links: [linked_entry.id])
      expect(fake.loaded).to be_nil
    end

    it "aborts when Timekeeping refuses the checkpoint" do
      fake.fail_next(:load_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "locked_not_derived" => [draft_entry.id] })

      failure = aborted_at

      expect(failure.step).to eq(:load)
      expect(failure.lists).to eq("locked_not_derived" => [draft_entry.id])
    end

    it "aborts when Timekeeping's reconcile finds a difference" do
      fake.fail_next(:reconcile_checkpoint, status: 409, slug: "checkpoint-differs", lists: { "entry_differs" => [linked_entry.id] })

      failure = aborted_at

      expect(failure.step).to eq(:reconcile_remote)
      expect(failure.lists).to eq("entry_differs" => [linked_entry.id])
    end

    it "aborts when this application's reconcile finds a billing value moved during the handoff" do
      line = draft.invoice_line_items.first
      moving = ->(_seconds) {
        fake.relay!
        InvoiceLineItem.where(id: line.id).update_all(rate: 101) # a write no fence sees
      }

      failure = aborted_at(tool(pause: moving))

      expect(failure.step).to eq(:reconcile_local)
      expect(failure.lists.keys).to eq([:money_differs])
      expect(failure.lists.fetch(:money_differs)).to include("invoice_line_items/#{line.id}/rate")
    end

    it "keeps the raised generation, so the next handoff starts at generation 2" do
      fake.fail_next(:reconcile_checkpoint, status: 409, slug: "checkpoint-differs", lists: { "entry_differs" => [linked_entry.id] })
      aborted_at

      expect(Timekeeping::Ownership.handoff_begun?).to be(true)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "leaves Timekeeping fenced for a resume when a refusal is retryable" do
      fake.fail_next(:reconcile_checkpoint, status: 503, slug: "drain-timeout", retryable: true)

      expect { tool.call }.to raise_error(Timekeeping::HandoffClient::Problem)
      expect(copies).to eq([[1, "legacy", "frozen"], [1, "legacy", "frozen"]])
    end
  end

  describe "#abort!" do
    it "reopens admission on both copies at the raised generation" do
      expect { tool(interrupt_before: :transfer).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(1)
      expect(copies).to eq(aborted)
      expect(steps_run).to eq(%w[close freeze abort])
    end

    it "reopens only this copy when Timekeeping's was never closed" do
      expect { tool(interrupt_before: :close_remote).call }.to raise_error(interrupted)

      expect(tool.abort!).to eq(1)
      expect(copies).to eq([[1, "legacy", "open"], [0, "legacy", "open"]])
      expect(steps_run).to be_empty
    end

    it "refuses when no handoff is in progress, changing nothing" do
      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[0, "legacy", "open"], [0, "legacy", "open"]])
    end

    it "refuses once Timekeeping's copy has flipped: past the flip the handoff only goes forward" do
      expect { tool(interrupt_before: :flip_local).call }.to raise_error(interrupted)

      expect { tool.abort! }.to raise_error(described_class::Unresumable, /nothing to abort/)
      expect(copies).to eq([[1, "legacy", "frozen"], [1, "timekeeping", "open"]])
    end
  end

  describe "copies no step of the cutover leaves" do
    {
      "Timekeeping's copy ahead of this one" => [{ generation: 0, owner: "legacy", state: "open" }, { generation: 1, state: "closed" }],
      "the two copies at different generations" => [{ generation: 2, owner: "legacy", state: "open" }, {}],
      "this copy frozen and Timekeeping's reopened by an abort" => [{ generation: 1, owner: "legacy", state: "frozen" }, { generation: 1 }],
      "a rollback under way" => [{ generation: 2, owner: "timekeeping", state: "frozen" }, { generation: 2, owner: "timekeeping", state: "frozen" }]
    }.each do |name, (local, remote)|
      it "refuses with #{name}, changing nothing" do
        set_timekeeping_ownership!(local)
        other = TimekeepingContracts::FakeHandoff.new(**remote).install!

        expect { tool.call }.to raise_error(described_class::Unresumable, /no step of the cutover leaves/)
        expect(other.calls.map(&:operation)).to eq(%i[read_handoff])
        expect(Timekeeping::Ownership.current.slice(:generation, :owner, :state).symbolize_keys).to eq(local)
      end
    end
  end
end
