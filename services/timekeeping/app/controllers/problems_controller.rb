# frozen_string_literal: true

# The exceptions app (config/application.rb): renders an error the framework
# raised before or around an action (an unknown route, an unknown HTTP method,
# an unparseable body) as a contract problem (§5.1). Endpoints answer their
# own problems; this covers what reaches no endpoint.
class ProblemsController < ActionController::API
  # The problem for each status Rails' rescue_responses can raise here. A status
  # with no problem type (a 500, for one) answers with no body, and the client
  # reads it as an answer outside the contract, which it is.
  SLUGS = {
    400 => "invalid-request",
    404 => "not-found",
    405 => "invalid-request",
    406 => "invalid-request"
  }.freeze

  def show
    status = request.path_info.delete_prefix("/").to_i
    slug = SLUGS[status]
    return head(status) unless slug

    render json: Problem.new(slug:, status:, detail: request.env["action_dispatch.exception"]&.message),
      status:, content_type: "application/problem+json"
  end
end
