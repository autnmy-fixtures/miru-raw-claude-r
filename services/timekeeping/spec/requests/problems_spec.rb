# frozen_string_literal: true

# §5.1: errors are application/problem+json with stable types, and the
# contracts read any non-2xx answer as common.json#/$defs/problem. These are
# the errors that reach no endpoint.
RSpec.describe "Errors that reach no endpoint" do
  def problem_body
    JSON.parse(response.body)
  end

  it "answers an unknown internal route with a not-found problem" do
    post "/internal/v1/no_such_route", params: { a: 1 }.to_json, headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/problem+json")
    expect(problem_body).to include(
      "type" => "https://contracts.timekeeping.internal/problems/not-found",
      "status" => 404,
      "retryable" => false
    )
    expect(contract_errors("common", "#/$defs/problem", problem_body)).to be_empty
  end

  it "answers an unknown HTTP method with an invalid-request problem" do
    process :get, "/internal/v1/entries", headers: { "REQUEST_METHOD" => "BREW" }

    expect(response).to have_http_status(:method_not_allowed)
    expect(problem_body).to include("type" => "https://contracts.timekeeping.internal/problems/invalid-request", "status" => 405)
    expect(contract_errors("common", "#/$defs/problem", problem_body)).to be_empty
  end
end
