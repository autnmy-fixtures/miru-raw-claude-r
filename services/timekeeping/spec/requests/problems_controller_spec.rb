# frozen_string_literal: true

# The exceptions app row by row: each status the framework can raise answers
# the problem its row names, and every body is one the contract allows.
RSpec.describe ProblemsController do
  def answer(status, exception)
    env = Rack::MockRequest.env_for("/#{status}", "REQUEST_METHOD" => "POST")
    env["action_dispatch.exception"] = exception
    status, headers, body = Rails.application.config.exceptions_app.call(env)
    [status, headers, body.each.to_a.join]
  end

  {
    400 => [ActionDispatch::Http::Parameters::ParseError.new("unexpected token"), "invalid-request"],
    404 => [ActionController::RoutingError.new("No route matches"), "not-found"],
    405 => [ActionController::UnknownHttpMethod.new("BREW"), "invalid-request"],
    406 => [ActionController::UnknownFormat.new("xml"), "invalid-request"]
  }.each do |status, (exception, slug)|
    it "answers #{status} with the #{slug} problem the contract allows" do
      answered, headers, body = answer(status, exception)
      problem = JSON.parse(body)

      expect(answered).to eq(status)
      expect(headers["content-type"]).to start_with("application/problem+json")
      expect(problem).to include(
        "type" => "https://contracts.timekeeping.internal/problems/#{slug}",
        "status" => status,
        "title" => Rack::Utils::HTTP_STATUS_CODES.fetch(status),
        "detail" => exception.message,
        "retryable" => false
      )
      expect(contract_errors("common", "#/$defs/problem", problem)).to be_empty
    end
  end

  it "maps only statuses the framework's rescue responses raise" do
    expect(described_class::SLUGS.keys).to all(satisfy { |status| ActionDispatch::ExceptionWrapper.rescue_responses.values.map { |symbol| Rack::Utils.status_code(symbol) }.include?(status) })
  end

  it "answers a status with no problem type with no body" do
    answered, _headers, body = answer(500, RuntimeError.new("boom"))

    expect(answered).to eq(500)
    expect(body).to be_empty
  end
end
