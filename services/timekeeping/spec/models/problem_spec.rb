# frozen_string_literal: true

RSpec.describe Problem do
  it "knows every problem type of the contracts, and only those" do
    expect(described_class.types.values).to eq(contract_document("common").dig("$defs", "problem_type", "enum"))
  end

  it "refuses a slug the contracts do not list" do
    expect { described_class.new(slug: "teapot", status: 418) }.to raise_error(ArgumentError, /teapot/)
  end

  it "renders a body the contract allows, retryable when asked" do
    problem = described_class.new(slug: "ownership-moving", status: 503, retryable: true).as_json

    expect(problem).to eq(
      "type" => "https://contracts.timekeeping.internal/problems/ownership-moving",
      "title" => "Service Unavailable",
      "status" => 503,
      "retryable" => true
    )
    expect(contract_errors("common", "#/$defs/problem", problem)).to be_empty
  end
end
