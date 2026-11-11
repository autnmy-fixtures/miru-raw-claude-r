# frozen_string_literal: true

# The `timekeeping` owner's side of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3), over HTTP: prepare of one
# ledger intent for the invoice reservation boundary, and commit and abort for
# the invoice operation worker. Paths, headers and bodies come from the
# reservation API contract, its one source of truth.
#
# Each call carries the intent's own generation and its operation id as the
# Idempotency-Key, so a resend after a lost response is the same request
# (§9.4), and a system-actor token for the intent's company (§6.1). Prepare
# answers Prepared, or the terminal Receipt Timekeeping stored for an
# operation already resolved; commit and abort answer the Receipt. Anything
# else raises: a problem Timekeeping answered, an answer outside the contract,
# or a transport error (Faraday::Error, a 2 s timeout included). This client
# never retries on its own: the boundary retries prepare (§9.4), and the
# worker's next sweep is the retry of commit and abort.
class Timekeeping::ReservationClient
  include Timekeeping::InternalApi

  CONTRACT = :reservation_api
  WRITER = "invoice"

  Receipt = Data.define(:status)
  # 200 prepared: the desired set's entries, authoritative for existence and
  # company (L8), with the facts line-item validation needs.
  Prepared = Data.define(:entries)
  PreparedEntry = Data.define(:id, :company_id, :project_id, :user_id, :duration, :work_date, :version)

  # A 200 answer by its status: prepare's own, or a stored terminal receipt.
  # The contract allows "prepared" only from prepare.
  ANSWERS = {
    "prepared" => ->(body) { Prepared.new(entries: body.fetch("entries").map { |entry| PreparedEntry.new(**entry.symbolize_keys) }) },
    "committed" => ->(body) { Receipt.new(status: body.fetch("status")) },
    "aborted" => ->(body) { Receipt.new(status: body.fetch("status")) }
  }.freeze

  # §9.2 step 2. `resolves` is nil, or the outcome of the invoice's earlier
  # operation Timekeeping may still hold unresolved (§5.3).
  def prepare(intent, invoice_state:, resolves:)
    request(:prepare, intent, {
      "company_id" => intent.company_id, "generation" => intent.generation, "kind" => intent.kind,
      "invoice_state" => invoice_state.to_s, "entry_ids" => intent.entry_ids, "resolves" => resolves
    })
  end

  def commit(intent) = request(:commit, intent, "generation" => intent.generation)

  def abort(intent) = request(:abort, intent, "generation" => intent.generation)

  private

    def request(name, intent, body)
      operation = contract_operation(name)
      response = http.post(path(operation, intent), JSON.generate(body), headers(intent))
      answer(operation, response).then { |answered| ANSWERS.fetch(answered.fetch("status")).call(answered) }
    end

    def path(operation, intent)
      operation.fetch("path")
        .sub("{invoice_id}", intent.invoice_id.to_s)
        .sub("{operation_id}", intent.operation_id)
    end

    def headers(intent)
      identity_headers(company: Company.find(intent.company_id), writer: WRITER).merge(
        "Idempotency-Key" => intent.operation_id,
        "X-Ownership-Generation" => intent.generation.to_s,
        "Content-Type" => "application/json"
      )
    end
end
