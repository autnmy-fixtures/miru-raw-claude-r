# frozen_string_literal: true

# The projection endpoint of docs/architecture/timekeeping-soa.md §5.4, where
# the Timekeeping relay delivers entry snapshot batches. It authenticates the
# relay and narrows the request to the entry snapshot contract;
# Timekeeping::ProjectionConsumer applies the batch. Every refusal is an
# application/problem+json the relay reads as "do not advance".
class Timekeeping::EntrySnapshotsController < ActionController::API
  CONTRACT = :entry_snapshot
  BATCH = "#/$defs/snapshot_batch"

  def create
    return problem("unauthenticated", :unauthorized) unless Timekeeping::ServiceToken.verify(request.authorization)

    errors = request_errors
    return problem("invalid-request", :bad_request, errors.join("; ")) if errors.any?

    render_outcome Timekeeping::ProjectionConsumer.process(batch.fetch("snapshots"))
  end

  private

    def request_errors
      missing = Timekeeping::Contracts.document(CONTRACT).dig("x-headers", "every").select { |name| request.headers[name].blank? }
      missing.map { |name| "missing header #{name}" } + Timekeeping::Contracts.errors(CONTRACT, BATCH, batch)
    end

    # The parsed body; nil for malformed JSON, which the contract then refuses.
    def batch
      @batch ||= JSON.parse(request.raw_post)
    rescue JSON::ParserError
      nil
    end

    def render_outcome(outcome)
      case outcome
      in Timekeeping::ProjectionConsumer::Applied
        render json: outcome.to_h
      in Timekeeping::ProjectionConsumer::Refused(entry_ids:)
        problem("forbidden", :forbidden, "entries #{entry_ids.join(', ')} belong to another company than the snapshot names")
      end
    end

    def problem(slug, status, detail = nil)
      code = Rack::Utils.status_code(status)
      body = {
        type: Timekeeping::Contracts.problem_type(slug), title: Rack::Utils::HTTP_STATUS_CODES.fetch(code),
        status: code, retryable: false, detail:
      }.compact
      render json: body, status: code, content_type: "application/problem+json"
    end
end
