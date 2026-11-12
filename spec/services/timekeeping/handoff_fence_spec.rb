# frozen_string_literal: true

require "rails_helper"

# The fence of the handoff procedure (docs/architecture/timekeeping-soa.md
# §10.5) on this application's ownership record (§10.1): close, freeze, flip
# and abort, each against the generation it expects. That a close waits for
# the writes already admitted, and that a write arriving during it is
# refused, is proven across connections by the gateway and billing-write
# admission specs, which close admission through this fence.
RSpec.describe Timekeeping::HandoffFence, type: :model do
  include TimekeepingOwnershipStates

  states = TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN

  def ownership
    Timekeeping::Ownership.current.attributes.symbolize_keys.slice(:generation, :owner, :state)
  end

  def step(name, generation)
    described_class.call(name, generation:)
    ownership
  end

  it "takes the record through cutover, rollback and re-cutover in the states the handoff leaves" do
    aggregate_failures do
      expect(step(:close, 0)).to eq(states.fetch("first handoff, admission closed"))
      expect(step(:freeze, 1)).to eq(states.fetch("first handoff, frozen"))
      expect(step(:flip, 1)).to eq(states.fetch("cut over to Timekeeping"))

      expect(step(:close, 1)).to eq(generation: 2, owner: "timekeeping", state: "closed")
      expect(step(:freeze, 2)).to eq(states.fetch("rollback, frozen"))
      expect(step(:flip, 2)).to eq(states.fetch("rolled back to the prepared application"))

      expect(step(:close, 2)).to eq(generation: 3, owner: "monolith", state: "closed")
      expect(step(:freeze, 3)).to eq(generation: 3, owner: "monolith", state: "frozen")
      expect(step(:flip, 3)).to eq(states.fetch("re-cut over to Timekeeping"))
    end
  end

  it "writes the record on a database where no handoff has run, and answers it as the step left it" do
    closed = described_class.call(:close, generation: 0)

    expect(closed).to be_persisted
    expect(closed.summary).to eq("generation 1, owner legacy, state closed")
  end

  it "never returns to legacy: a rollback goes to the prepared application" do
    set_timekeeping_ownership!(generation: 4, owner: "timekeeping", state: "frozen")

    expect(step(:flip, 4)).to eq(generation: 4, owner: "monolith", state: "open")
  end

  describe "abort" do
    it "reopens a closed handoff under the outgoing owner and keeps the raised generation" do
      described_class.call(:close, generation: 0)

      expect(step(:abort, 1)).to eq(states.fetch("first handoff aborted"))
      expect(Timekeeping::Ownership.handoff_begun?).to be(true)
    end

    it "reopens a frozen rollback under Timekeeping" do
      set_timekeeping_ownership!(states.fetch("rollback, frozen"))

      expect(step(:abort, 2)).to eq(generation: 2, owner: "timekeeping", state: "open")
    end

    it "lets the next handoff start from the raised generation" do
      described_class.call(:close, generation: 0)
      described_class.call(:abort, generation: 1)

      expect(step(:close, 1)).to eq(generation: 2, owner: "legacy", state: "closed")
    end
  end

  describe "a step out of step" do
    {
      "a freeze before admission closed" => [:freeze, { generation: 0, owner: "legacy", state: "open" }],
      "a flip before the freeze" => [:flip, { generation: 1, owner: "legacy", state: "closed" }],
      "a second close of a closed handoff" => [:close, { generation: 1, owner: "legacy", state: "closed" }],
      "an abort with no handoff running" => [:abort, { generation: 1, owner: "timekeeping", state: "open" }]
    }.each do |name, (step_name, record)|
      it "refuses #{name} and changes nothing" do
        set_timekeeping_ownership!(record)

        expect { described_class.call(step_name, generation: record.fetch(:generation)) }
          .to raise_error(described_class::OutOfStep, /#{step_name} expects generation #{record.fetch(:generation)}/)
        expect(ownership).to eq(record)
      end
    end

    it "refuses a step that names another generation, as a second tool or a re-run step would" do
      set_timekeeping_ownership!(generation: 2, owner: "timekeeping", state: "closed")

      expect { described_class.call(:freeze, generation: 1) }.to raise_error(
        described_class::OutOfStep,
        "Timekeeping handoff: freeze expects generation 1 in state closed, " \
        "found generation 2, owner timekeeping, state closed; nothing changed"
      )
      expect { described_class.call(:close, generation: 1) }.to raise_error(described_class::OutOfStep)
      expect(ownership).to eq(generation: 2, owner: "timekeeping", state: "closed")
    end

    it "refuses to freeze while the invoice operation ledger is not settled, and changes nothing (§10.5 step 2)" do
      set_timekeeping_ownership!(generation: 2, owner: "timekeeping", state: "closed")
      pending, undelivered = [%w[pending 701], %w[failed 702]].map do |state, invoice_id|
        Timekeeping::InvoiceOperation.create!(
          operation_id: SecureRandom.uuid, invoice_id:, company_id: 1, kind: "save", entry_ids: [], state:, generation: 1
        )
      end
      Timekeeping::InvoiceOperation.create!(
        operation_id: SecureRandom.uuid, invoice_id: 703, company_id: 1, kind: "save", entry_ids: [], state: "succeeded", generation: 1,
        delivered_at: Time.current
      )

      expect { described_class.call(:freeze, generation: 2) }.to raise_error(
        described_class::Unsettled,
        "Timekeeping handoff: freeze refused, 2 invoice operation(s) not settled " \
        "(pending #{pending.operation_id}; failed #{undelivered.operation_id}); nothing changed"
      )
      expect(ownership).to eq(generation: 2, owner: "timekeeping", state: "closed")

      [pending, undelivered].each { |intent| intent.update!(state: "failed", delivered_at: Time.current) }
      expect(step(:freeze, 2)).to eq(states.fetch("rollback, frozen"))
    end

    it "refuses a step the procedure does not have" do
      expect { described_class.call(:settle, generation: 0) }.to raise_error(KeyError)
      expect(Timekeeping::Ownership.current).to be_new_record
    end
  end

  describe "writers after a close" do
    include_context "with two Timekeeping tenants"

    it "refuses an entry command and an invoice operation as moving, and admits them again after an abort" do
      gateway = Timekeeping::Gateway
      command = gateway::BulkDiscard.new(entries: TimesheetEntry.none, company: tenant_a.company)
      open_intent = -> {
        Timekeeping::InvoiceOperation.open!(invoice_id: 1, company_id: tenant_a.company.id, kind: :save)
      }
      described_class.call(:close, generation: 0)

      aggregate_failures do
        expect { gateway.call(command) }.to raise_error(Timekeeping::Ownership::Moving)
        expect { open_intent.call }.to raise_error(Timekeeping::Ownership::Moving)
      end

      described_class.call(:abort, generation: 1)

      expect(gateway.call(command)).to eq([])
      expect(open_intent.call.generation).to eq(1)
    end
  end
end
