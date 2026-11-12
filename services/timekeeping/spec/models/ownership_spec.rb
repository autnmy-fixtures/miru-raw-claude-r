# frozen_string_literal: true

require "rails_helper"

# Timekeeping's copy of the ownership record (docs/architecture/timekeeping-soa.md
# §10.1) and the admission every mutating call passes (§5.1): the generation
# the call carries must be this copy's, Timekeeping must own entries, and
# admission must be open.
RSpec.describe Ownership do
  def problem_of(generation)
    described_class.admit!(generation)
    nil
  rescue described_class::Refused => refused
    refused.problem
  end

  def record!(**attributes)
    described_class.current.tap { |ownership| ownership.update!(attributes) }
  end

  it "reads the initial legacy state, unsaved, on a database where no handoff has run" do
    current = described_class.current

    expect(current).to be_new_record
    expect(current.summary).to eq("generation 0, owner legacy, state open")
  end

  it "holds one row: the database refuses a second" do
    record!(generation: 0)

    expect { described_class.insert({ id: 2 }) }.to raise_error(ActiveRecord::StatementInvalid, /ownerships_singleton/)
  end

  it "admits a call carrying this copy's generation while Timekeeping owns entries and admission is open" do
    record!(generation: 1, owner: "timekeeping", state: "open")

    expect(described_class.admit!(1).summary).to eq("generation 1, owner timekeeping, state open")
  end

  {
    "carries an older generation" => [{ generation: 2, owner: "timekeeping", state: "open" }, 1],
    "carries a newer generation" => [{ generation: 1, owner: "timekeeping", state: "open" }, 2],
    "arrives before the first cutover" => [{ generation: 0, owner: "legacy", state: "open" }, 0],
    "arrives after a rollback" => [{ generation: 2, owner: "monolith", state: "open" }, 2],
    "carries the old generation after close" => [{ generation: 2, owner: "timekeeping", state: "closed" }, 1]
  }.each do |name, (attributes, carried)|
    it "refuses a call that #{name} as 409 stale-generation" do
      record!(**attributes)

      expect(problem_of(carried)).to have_attributes(slug: "stale-generation", status: 409, retryable: false)
    end
  end

  {
    "closed" => { generation: 2, owner: "timekeeping", state: "closed" },
    "frozen" => { generation: 2, owner: "timekeeping", state: "frozen" }
  }.each do |state, attributes|
    it "refuses a call at this generation while admission is #{state} as a retryable 503 ownership-moving" do
      record!(**attributes)

      expect(problem_of(2)).to have_attributes(slug: "ownership-moving", status: 503, retryable: true)
    end
  end

  it "answers each refusal as a problem the contract accepts, naming what it carried and what this copy holds" do
    record!(generation: 2, owner: "timekeeping", state: "closed")

    [problem_of(1), problem_of(2)].each do |problem|
      expect(contract_errors("common", "#/$defs/problem", problem.as_json)).to be_empty
    end
    expect(problem_of(1).detail).to eq(
      "X-Ownership-Generation 1 refused: Timekeeping holds generation 2, owner timekeeping, state closed"
    )
  end

  it "writes the initial row to lock on a database where no handoff has run, and refuses the call" do
    expect(problem_of(0)).to have_attributes(slug: "stale-generation")
    expect(described_class.current).to be_persisted
    expect(described_class.current.summary).to eq("generation 0, owner legacy, state open")
  end
end
