# frozen_string_literal: true

# The `timekeeping` owner's entry API (docs/architecture/timekeeping-soa.md
# §5.2), over HTTP, for the reads that decide money (§3.3 rule 1). So far it
# serves invoice candidate selection: kept, unbilled entries of the given
# projects that hold no active or provisional reservation, read from the
# owner instead of the projection, which may lag (§12.4 "relay paused").
#
# The call carries a system-actor token for the company (§6.1), which scopes
# it to that tenant (§6.3); who may select candidates was already decided
# here, by InvoiceLineItemPolicy. A transport failure or any 5xx raises
# Unavailable, which the caller answers as a retryable 503. Anything else
# Timekeeping answers outside the contract raises as in every client.
class Timekeeping::EntryClient
  include Timekeeping::InternalApi

  CONTRACT = :entry_api
  WRITER = "invoice"

  # What candidate selection reads of one entry.
  Candidate = Data.define(:id, :company_id, :project_id, :user_id, :note, :work_date, :duration)

  # Timekeeping could not answer now: down, timed out, or a 5xx. Nothing was
  # read, and the same request may succeed later.
  class Unavailable < Timekeeping::InternalApi::Error; end

  # `project_ids` and `user_ids` restrict the candidates to those ids; nil
  # `user_ids` is no restriction. An empty list selects nothing, as an empty
  # IN list does in SQL, and a query string cannot carry one, so no call is
  # made for it. `work_dates` is an inclusive Range of Dates, or nil.
  def candidates(company:, client_id:, project_ids:, user_ids: nil, exclude_ids: [], work_dates: nil, search_term: nil)
    return [] if project_ids.empty? || user_ids&.empty?

    query = {
      "client_id" => client_id, "project_ids" => project_ids, "user_ids" => user_ids,
      "exclude_ids" => exclude_ids.presence, "from" => work_dates&.begin&.iso8601, "to" => work_dates&.end&.iso8601,
      "search_term" => search_term
    }.compact
    read(:candidates, query, company:).fetch("entries").map { |entry| candidate(entry) }
  end

  private

    def read(name, query, company:)
      operation = contract_operation(name)
      response = http.get(operation.fetch("path"), query, identity_headers(company:, writer: WRITER))
      raise Unavailable, "Timekeeping #{name}: HTTP #{response.status}" if response.status >= 500

      answer(operation, response)
    rescue Faraday::Error => error
      raise Unavailable, "Timekeeping #{name}: #{error.message}"
    end

    def candidate(entry)
      Candidate.new(
        id: entry.fetch("id"), company_id: entry.fetch("company_id"), project_id: entry.fetch("project_id"),
        user_id: entry.fetch("user_id"), note: entry.fetch("note"), work_date: Date.iso8601(entry.fetch("work_date")),
        duration: entry.fetch("duration")
      )
    end
end
