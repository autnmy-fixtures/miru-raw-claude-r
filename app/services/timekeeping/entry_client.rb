# frozen_string_literal: true

# The `timekeeping` owner's entry API (docs/architecture/timekeeping-soa.md
# §5.2), over HTTP.
#
# Reads that decide money (§3.3 rule 1): invoice candidate selection, kept,
# unbilled entries of the given projects that hold no active or provisional
# reservation, read from the owner instead of the projection, which may lag
# (§12.4 "relay paused"). The call carries a system-actor token for the
# company (§6.1), which scopes it to that tenant (§6.3); who may select
# candidates was already decided here, by InvoiceLineItemPolicy.
#
# Reads a user makes right after writing (§3.3 rule 1): the entry API's own
# list and show, for Timekeeping::EntryReads. Each carries the caller's
# claims, whose company scopes it (§6.3); who may read was already decided
# here, by the caller's policy.
#
# Entry writes, single and bulk, import batches and agent detach, for the
# write gateway (§3.1): each carries the caller's claims (§6.1), the admitted
# ownership generation and one Idempotency-Key (§5.1). A request the contract
# cannot carry raises Invalid and is never sent. A transport failure or a 5xx is
# retried at most twice with jitter, with the same key, so a retry after a
# lost response replays the stored result (§9.4).
#
# A transport failure or any 5xx that remains raises Unavailable, which the
# caller answers as a retryable 503. A problem Timekeeping answered raises
# Problem, and anything else it answers outside the contract raises as in
# every client.
class Timekeeping::EntryClient < Timekeeping::InternalApi
  CONTRACT = :entry_api
  WRITER = "invoice"
  ATTEMPTS = 3 # total, so at most 2 retries (§9.4)
  JITTER = 0.05..0.2 # seconds before a retry

  # What candidate selection reads of one entry.
  Candidate = Data.define(:id, :company_id, :project_id, :user_id, :note, :work_date, :duration)

  # Timekeeping could not answer now: down, timed out, or a 5xx. Nothing was
  # read, and the same request may succeed later.
  class Unavailable < Timekeeping::InternalApi::Error; end

  # The request breaks the entry API contract, so it was not sent.
  class Invalid < Timekeeping::InternalApi::Error
    attr_reader :errors

    def initialize(operation, errors)
      @errors = errors
      super("Timekeeping #{operation}: #{errors.join('; ')}")
    end
  end

  # One entry write: who is calling (the claims of §6.1), under which
  # generation, and the key its retries share.
  Write = Data.define(:claims, :generation, :idempotency_key)

  def initialize(backoff: ->(seconds) { sleep(seconds) }, **)
    super(**)
    @backoff = backoff
  end

  # Each answers the owner's full entry (§5.2), as the contract states it.
  def create_entry(entry, write:) = mutate(:create_entry, { "entry" => entry }, write:).fetch("entry")

  def update_entry(id, entry, write:) = mutate(:update_entry, { "entry" => entry }, write:, id:).fetch("entry")

  def discard_entry(id, write:) = mutate(:discard_entry, {}, write:, id:).fetch("entry")

  # W2 (§5.2). Each takes the ids the caller's policy scope selected. A bulk
  # move answers every entry it moved or skipped (A9), as the owner holds it
  # after the move; a bulk discard answers the ids it discarded. No ids
  # selects nothing, which the contract cannot carry, so no call is made.
  def bulk_move(ids, project_id, write:)
    return [] if ids.empty?

    mutate(:bulk_move, { "ids" => ids, "project_id" => project_id }, write:).fetch("entries")
  end

  def bulk_discard(ids, write:)
    return [] if ids.empty?

    mutate(:bulk_discard, { "ids" => ids }, write:).fetch("discarded_ids")
  end

  # W5 (§5.2, §3.4): one Harvest batch of at most 500 rows, which the owner
  # writes in one transaction. The import id and batch number name it in the
  # path, and its retries share one key. Answers the ids it created and the
  # rows it rejected, by index in the batch, with the model's errors.
  def import_batch(import_id, batch_no, rows, write:)
    mutate(:import_batch, { "rows" => rows }, write:, import_id:, n: batch_no)
  end

  # W6 (§5.2): nulls agent_id on the token company's entries that name the
  # agent, and answers the ids it changed. Detaching an agent that no entry
  # names changes nothing, so a repeat is harmless.
  def detach_agent(agent_id, write:) = mutate(:detach_agent, {}, write:, agent_id:).fetch("detached_ids")

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
    claims = Timekeeping::UserToken.system_claims(company:, writer: WRITER, request_id: SecureRandom.uuid)
    read(:candidates, query, claims:).fetch("entries").map { |entry| candidate(entry) }
  end

  # The kept entries of the claims' company for the user, with work dates in
  # the inclusive Range of Dates, as the owner holds them (§5.2), every page
  # of them: the owner answers a next_cursor until the last page.
  def list_entries(user_id:, work_dates:, claims:)
    query = { "user_id" => user_id.to_s, "from" => work_dates.begin.iso8601, "to" => work_dates.end.iso8601 }
    entries, cursor = [], nil
    loop do
      page = read(:list_entries, query.merge("cursor" => cursor).compact, claims:)
      entries.concat(page.fetch("entries"))
      break unless (cursor = page.fetch("next_cursor"))
    end
    entries
  end

  # One kept entry of the claims' company, as the owner holds it (§5.2). One
  # the owner does not hold there answers Problem not-found.
  def show_entry(id, claims:) = read(:show_entry, {}, claims:, id:).fetch("entry")

  private

    # `path_params` fills the operation's path template, such as {id}.
    def mutate(name, body, write:, **path_params)
      operation = contract_operation(name)
      errors = Timekeeping::Contracts.errors(CONTRACT, operation.fetch("request"), body)
      raise Invalid.new(name, errors) if errors.any?

      headers = token_headers(write.claims).merge(
        "Idempotency-Key" => write.idempotency_key,
        "X-Ownership-Generation" => write.generation.to_s,
        "Content-Type" => "application/json"
      )
      answer(operation, retrying(name) { http.run_request(operation.fetch("method").downcase.to_sym, path(operation, path_params), JSON.generate(body), headers) })
    end

    # The operation's path template, such as {id}, filled from path_params.
    def path(operation, path_params)
      operation.fetch("path").gsub(/\{(\w+)\}/) { path_params.fetch(Regexp.last_match(1).to_sym).to_s }
    end

    # The response of the first attempt Timekeeping answered below 500, or
    # Unavailable once every attempt failed.
    def retrying(name, &request)
      outcome = nil
      ATTEMPTS.times do |attempt|
        @backoff.call(rand(JITTER)) if attempt.positive?
        outcome = attempt_once(&request)
        return outcome if outcome.is_a?(Faraday::Response) && outcome.status < 500
      end
      raise Unavailable, "Timekeeping #{name}: #{failure(outcome)}"
    end

    def attempt_once
      yield
    rescue Faraday::Error => error
      error
    end

    def failure(outcome)
      outcome.is_a?(Faraday::Response) ? "HTTP #{outcome.status}" : outcome.message
    end

    def read(name, query, claims:, **path_params)
      operation = contract_operation(name)
      response = http.get(path(operation, path_params), query, token_headers(claims))
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
