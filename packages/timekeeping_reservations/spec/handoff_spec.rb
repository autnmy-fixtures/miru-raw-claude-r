# frozen_string_literal: true

require_relative "../lib/timekeeping_reservations"

# The handoff's state machine over the ownership record
# (docs/architecture/timekeeping-soa.md §10.1, §10.5), tested once, here.
# Both fences, the existing application's and Timekeeping's, persist what it
# decides; their own specs prove the locking.
RSpec.describe TimekeepingReservations::Handoff do
  let(:record_type) { Data.define(:generation, :owner, :state) }

  def record(**attributes) = record_type.new(**attributes)

  def run(record, name, generation = record.generation)
    record.with(**described_class::STEPS.fetch(name).apply(record, generation:))
  end

  it "takes the record through cutover, rollback and re-cutover" do
    journey = %i[close freeze flip close freeze flip close freeze flip]
    records = journey.each_with_object([record(generation: 0, owner: "legacy", state: "open")]) do |name, path|
      path << run(path.last, name)
    end

    expect(records.drop(1).map(&:to_h)).to eq([
      { generation: 1, owner: "legacy", state: "closed" },
      { generation: 1, owner: "legacy", state: "frozen" },
      { generation: 1, owner: "timekeeping", state: "open" },
      { generation: 2, owner: "timekeeping", state: "closed" },
      { generation: 2, owner: "timekeeping", state: "frozen" },
      { generation: 2, owner: "monolith", state: "open" },
      { generation: 3, owner: "monolith", state: "closed" },
      { generation: 3, owner: "monolith", state: "frozen" },
      { generation: 3, owner: "timekeeping", state: "open" }
    ])
  end

  it "never returns to legacy: every owner has exactly one successor" do
    expect(described_class::SUCCESSORS).to eq(
      "legacy" => "timekeeping", "timekeeping" => "monolith", "monolith" => "timekeeping"
    )
  end

  {
    "a closed handoff" => { generation: 1, owner: "legacy", state: "closed" },
    "a frozen handoff" => { generation: 2, owner: "timekeeping", state: "frozen" }
  }.each do |name, attributes|
    it "aborts #{name} to open under the outgoing owner and keeps the raised generation" do
      expect(run(record(**attributes), :abort).to_h).to eq(attributes.merge(state: "open"))
    end
  end

  describe "a step out of step" do
    {
      "a freeze before admission closed" => [:freeze, { generation: 0, owner: "legacy", state: "open" }],
      "a flip before the freeze" => [:flip, { generation: 1, owner: "legacy", state: "closed" }],
      "a second close of a closed handoff" => [:close, { generation: 1, owner: "legacy", state: "closed" }],
      "an abort with no handoff running" => [:abort, { generation: 1, owner: "timekeeping", state: "open" }]
    }.each do |name, (step, attributes)|
      it "refuses #{name}" do
        expect { run(record(**attributes), step) }.to raise_error(described_class::OutOfStep, /#{step} expects generation/)
      end
    end

    it "refuses a step that names another generation, as a second tool or a re-run step would" do
      closed = record(generation: 2, owner: "timekeeping", state: "closed")

      expect { run(closed, :freeze, 1) }.to raise_error(
        described_class::OutOfStep,
        "Timekeeping handoff: freeze expects generation 1 in state closed, " \
        "found generation 2, owner timekeeping, state closed; nothing changed"
      )
    end

    it "has no step the procedure does not have" do
      expect(described_class::STEPS.keys).to eq(%i[close freeze flip abort])
    end
  end
end
