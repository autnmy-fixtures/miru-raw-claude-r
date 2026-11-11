# frozen_string_literal: true

module TimekeepingContracts
  # Drives the fake's reservation API over HTTP as the invoice boundary will,
  # so the invoice operation worker's specs can put an operation in the state
  # a save would leave it in before delivery.
  module ReservationDriver
    def reservation_call(name, intent, body)
      operation = TimekeepingContracts.operation(name)
      Faraday.new(url: FakeTimekeeping::URL) { |connection| connection.response :json }.post(
        operation.path_for(invoice_id: intent.invoice_id, operation_id: intent.operation_id),
        JSON.generate(body),
        "Authorization" => "Bearer #{TimekeepingContracts.user_token(company_id: intent.company_id, writer: 'invoice')}",
        "X-Request-Id" => SecureRandom.uuid, "Idempotency-Key" => intent.operation_id,
        "X-Ownership-Generation" => intent.generation.to_s, "Content-Type" => "application/json"
      )
    end

    # §9.2 step 2 for the intent's desired set.
    def prepare_in_timekeeping(intent, invoice_state: "draft")
      reservation_call(:prepare, intent, {
        "company_id" => intent.company_id, "generation" => intent.generation, "kind" => intent.kind,
        "invoice_state" => invoice_state, "entry_ids" => intent.entry_ids, "resolves" => nil
      }).tap { |response| raise "prepare answered #{response.status}: #{response.body}" unless response.status == 200 }
    end
  end
end
