# frozen_string_literal: true

require "rails_helper"

# The handoff fence on Timekeeping's copy of the ownership record
# (docs/architecture/timekeeping-soa.md §10.1, §10.5). The steps themselves
# are the shared state machine, tested in its package; this proves the fence
# persists them, refuses out of step with nothing changed, and that what it
# leaves is what admission reads.
RSpec.describe HandoffFence do
  def ownership
    Ownership.current.attributes.symbolize_keys.slice(:generation, :owner, :state)
  end

  def step(name, generation)
    described_class.call(name, generation:)
    ownership
  end

  it "takes the record through cutover, rollback and re-cutover" do
    aggregate_failures do
      expect(step(:close, 0)).to eq(generation: 1, owner: "legacy", state: "closed")
      expect(step(:freeze, 1)).to eq(generation: 1, owner: "legacy", state: "frozen")
      expect(step(:flip, 1)).to eq(generation: 1, owner: "timekeeping", state: "open")

      expect(step(:close, 1)).to eq(generation: 2, owner: "timekeeping", state: "closed")
      expect(step(:freeze, 2)).to eq(generation: 2, owner: "timekeeping", state: "frozen")
      expect(step(:flip, 2)).to eq(generation: 2, owner: "monolith", state: "open")

      expect(step(:close, 2)).to eq(generation: 3, owner: "monolith", state: "closed")
      expect(step(:freeze, 3)).to eq(generation: 3, owner: "monolith", state: "frozen")
      expect(step(:flip, 3)).to eq(generation: 3, owner: "timekeeping", state: "open")
    end
  end

  def admits?(generation)
    Ownership.admit!(generation)
    true
  rescue Ownership::Refused
    false
  end

  it "leaves a record admission reads: calls are admitted only while Timekeeping owns entries, at its generation" do
    expect(admits?(0)).to be(false)

    step(:close, 0)
    step(:freeze, 1)
    step(:flip, 1)
    expect([admits?(0), admits?(1)]).to eq([false, true])

    step(:close, 1)
    expect([admits?(1), admits?(2)]).to eq([false, false])

    step(:abort, 2)
    expect([admits?(1), admits?(2)]).to eq([false, true])
  end

  it "writes the record on a database where no handoff has run, and answers it as the step left it" do
    closed = described_class.call(:close, generation: 0)

    expect(closed).to be_persisted
    expect(closed.summary).to eq("generation 1, owner legacy, state closed")
  end

  it "refuses a step out of step and changes nothing" do
    Ownership.current.update!(generation: 2, owner: "timekeeping", state: "closed")

    expect { described_class.call(:freeze, generation: 1) }.to raise_error(described_class::OutOfStep, /freeze expects generation 1/)
    expect { described_class.call(:close, generation: 2) }.to raise_error(described_class::OutOfStep, /close expects generation 2 in state open/)
    expect(ownership).to eq(generation: 2, owner: "timekeeping", state: "closed")
  end

  it "refuses a step the procedure does not have, before it writes any row" do
    expect { described_class.call(:settle, generation: 0) }.to raise_error(KeyError)
    expect(Ownership.current).to be_new_record
  end
end
