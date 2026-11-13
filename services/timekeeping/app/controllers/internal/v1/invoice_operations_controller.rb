# frozen_string_literal: true

# The reservation API (docs/architecture/timekeeping-soa.md §5.3): prepare,
# commit and abort of one invoice operation, each one mutating call run by
# ReservationProtocol. The invoice reservation boundary prepares; the invoice
# operation worker commits and aborts.
#
# Its idempotency is by (invoice_id, operation_id), not by entry API
# receipts, so the Idempotency-Key must be the path's operation_id, and the
# body's generation must be X-Ownership-Generation (reservation_api.json).
#
# The actions are named after the contract's operations with a suffix, as
# `abort` would shadow Kernel#abort.
class Internal::V1::InvoiceOperationsController < Internal::BaseController
  CONTRACT = :reservation_api

  def prepare_operation
    input = contract_input!("#/$defs/prepare_request", request.request_parameters)
    answer!(call_for(input)) { |call| ReservationProtocol.prepare(call, input) }
  end

  def commit_operation
    input = contract_input!("#/$defs/resolve_request", request.request_parameters)
    answer!(call_for(input)) { |call| ReservationProtocol.commit(call) }
  end

  def abort_operation
    input = contract_input!("#/$defs/resolve_request", request.request_parameters)
    answer!(call_for(input)) { |call| ReservationProtocol.abort(call) }
  end

  private

    def call_for(input)
      operation_id = params[:operation_id].downcase
      generation = carried_generation
      refuse!("invalid-request", 400, "Idempotency-Key must be the operation_id") unless request.headers["Idempotency-Key"].downcase == operation_id
      refuse!("invalid-request", 400, "body generation differs from X-Ownership-Generation") unless input.fetch("generation") == generation

      ReservationProtocol::Call.new(claims:, invoice_id: Integer(params[:invoice_id], 10), operation_id:, generation:)
    end

    # A reservation-refused prepare is answered, not raised (ReservationProtocol),
    # so its body is a problem like every other refusal.
    def answer!(call)
      status, body = yield call
      render json: body, status:, content_type: status >= 400 ? "application/problem+json" : "application/json"
    end
end
