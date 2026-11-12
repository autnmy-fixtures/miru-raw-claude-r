# frozen_string_literal: true

require "rails_helper"

# The consumer-side fake of Timekeeping holds to the entry API and reservation
# API contracts (docs/architecture/timekeeping-soa.md §5.2, §5.3, §12.3). It is
# driven over HTTP, as the gateway and the invoice boundary will drive it.
RSpec.describe TimekeepingContracts::FakeTimekeeping do
  subject!(:fake) { described_class.new(generation: 3).install! }

  let(:company_a) { 42 }
  let(:company_b) { 43 }
  let(:http) { Faraday.new(url: described_class::URL) { |connection| connection.response :json } }
  let(:row) { { "project_id" => 7, "user_id" => 3, "duration" => 90.7, "work_date" => "2026-11-02" } }

  def request(operation_name, company_id: company_a, generation: 3, key: SecureRandom.uuid, body: nil, query: nil, token: nil, **params)
    operation = TimekeepingContracts.operation(operation_name)
    headers = {
      "Authorization" => "Bearer #{token || TimekeepingContracts.user_token(company_id:)}",
      "X-Request-Id" => SecureRandom.uuid
    }
    headers.merge!("Idempotency-Key" => key, "X-Ownership-Generation" => generation.to_s, "Content-Type" => "application/json") if operation.mutating
    http.run_request(operation.verb.downcase.to_sym, operation.path_for(**params), body && JSON.generate(body), headers) do |request|
      request.params.update(query) if query
    end
  end

  def create_entry(company_id: company_a, **attributes)
    request(:create_entry, company_id:, body: { "entry" => row.merge(attributes.transform_keys(&:to_s)) }).body.fetch("entry")
  end

  after { expect(fake.violations).to be_empty unless RSpec.current_example.metadata[:violates] }

  describe "entry API" do
    it "creates an entry with its tenant, agent and version, and shows it" do
      token = TimekeepingContracts.user_token(company_id: company_a, actor: { "type" => "agent", "agent_id" => 5 }, writer: "agent")
      created = request(:create_entry, token:, body: { "entry" => row })

      expect(created.status).to eq(201)
      expect(created.body["entry"]).to include("company_id" => company_a, "agent_id" => 5, "version" => 1, "duration" => 90.7, "locked" => false)
      expect(request(:show_entry, id: created.body.dig("entry", "id")).body["entry"]).to eq(created.body["entry"])
    end

    it "raises the version on every change and discards" do
      entry = create_entry

      updated = request(:update_entry, id: entry["id"], body: { "entry" => { "note" => "standup" } }).body["entry"]
      discarded = request(:discard_entry, id: entry["id"], body: {}).body["entry"]

      expect([updated["version"], updated["note"]]).to eq([2, "standup"])
      expect(discarded["version"]).to eq(3)
      expect(discarded["discarded_at"]).to be_present
      expect(request(:show_entry, id: entry["id"]).status).to eq(404)
    end

    it "moves, discards, imports and detaches in bulk" do
      first, second = create_entry, create_entry
      fake.seed_entry(company_id: company_a, **row.symbolize_keys, agent_id: 9)

      moved = request(:bulk_move, body: { "ids" => [first["id"]], "project_id" => 8 }).body
      imported = request(:import_batch, import_id: "harvest-1", n: 1, body: { "rows" => [row, row] }).body
      detached = request(:detach_agent, agent_id: 9, body: {}).body
      discarded = request(:bulk_discard, body: { "ids" => [second["id"]] }).body

      expect(moved).to include("moved_ids" => [first["id"]], "skipped_ids" => [])
      expect(moved["entries"].first["project_id"]).to eq(8)
      expect(imported["created_ids"].size).to eq(2)
      expect(imported["failed_rows"]).to eq([])
      expect(detached["detached_ids"].size).to eq(1)
      expect(discarded["discarded_ids"]).to eq([second["id"]])
    end

    it "lists by user and date" do
      kept = create_entry(work_date: "2026-11-03")
      create_entry(user_id: 4, work_date: "2026-11-03")
      create_entry(work_date: "2026-10-01")

      listed = request(:list_entries, query: { "user_id" => "3", "from" => "2026-11-01", "to" => "2026-11-30" }).body

      expect(listed["entries"].pluck("id")).to eq([kept["id"]])
      expect(listed["next_cursor"]).to be_nil
    end

    it "lists by ids, alone or with a user (W2's selection)" do
      mine = create_entry(work_date: "2026-11-03")
      theirs = create_entry(user_id: 4, work_date: "2026-11-03")
      create_entry(work_date: "2026-11-04")
      ids = [mine, theirs].map { |entry| entry["id"].to_s }

      expect(request(:list_entries, query: { "ids" => ids }).body["entries"].pluck("id")).to eq([mine["id"], theirs["id"]])
      expect(request(:list_entries, query: { "ids" => ids, "user_id" => "3" }).body["entries"].pluck("id")).to eq([mine["id"]])
    end

    it "lists by projects and dates (W5's duplicate check)" do
      on_seven = create_entry(work_date: "2026-11-03")
      on_eight = create_entry(project_id: 8, work_date: "2026-11-04")
      create_entry(project_id: 9, work_date: "2026-11-03")
      create_entry(work_date: "2026-10-01")
      query = { "project_ids" => %w[7 8], "from" => "2026-11-01", "to" => "2026-11-30" }

      expect(request(:list_entries, query:).body["entries"].pluck("id")).to eq([on_seven["id"], on_eight["id"]])
    end

    it "replays a retried write and refuses a reused key with another body" do
      first = request(:create_entry, key: "retry-1", body: { "entry" => row })
      retried = request(:create_entry, key: "retry-1", body: { "entry" => row })
      reused = request(:create_entry, key: "retry-1", body: { "entry" => row.merge("note" => "other") })

      expect(retried.body).to eq(first.body)
      expect(request(:list_entries).body["entries"].size).to eq(1)
      expect(reused.status).to eq(409)
      expect(reused.body["type"]).to eq(TimekeepingContracts.problem_type("idempotency-conflict"))
    end
  end

  describe "tenant isolation" do
    it "neither shows, changes, lists, moves nor detaches another company's entries" do
      entry = create_entry(company_id: company_a)

      expect(request(:show_entry, company_id: company_b, id: entry["id"]).status).to eq(404)
      expect(request(:update_entry, company_id: company_b, id: entry["id"], body: { "entry" => { "note" => "x" } }).status).to eq(404)
      expect(request(:list_entries, company_id: company_b).body["entries"]).to eq([])
      expect(request(:bulk_move, company_id: company_b, body: { "ids" => [entry["id"]], "project_id" => 8 }).body["moved_ids"]).to eq([])
      expect(fake.entry(entry["id"])).to eq(entry)
    end
  end

  describe "ownership generation" do
    it "refuses a stale generation and changes nothing" do
      refused = request(:create_entry, generation: 2, body: { "entry" => row })

      expect(refused.status).to eq(409)
      expect(refused.body["type"]).to eq(TimekeepingContracts.problem_type("stale-generation"))
      expect(request(:list_entries).body["entries"]).to eq([])
    end

    it "admits the raised generation once the handoff raises it" do
      fake.generation = 4

      expect(request(:create_entry, generation: 3, body: { "entry" => row }).status).to eq(409)
      expect(request(:create_entry, generation: 4, body: { "entry" => row }).status).to eq(201)
    end
  end

  describe "contract checks", :violates do
    it "answers 400 and records a body the contract refuses" do
      response = request(:create_entry, body: { "entry" => row.merge("locked" => true) })

      expect(response.status).to eq(400)
      expect(response.body["type"]).to eq(TimekeepingContracts.problem_type("invalid-request"))
      expect(fake.violations.first).to include("locked")
    end

    it "answers 400 for a mutating call without its idempotency key" do
      response = http.post("/internal/v1/entries", JSON.generate("entry" => row), {
        "Authorization" => "Bearer #{TimekeepingContracts.user_token(company_id: company_a)}",
        "X-Request-Id" => "r", "X-Ownership-Generation" => "3", "Content-Type" => "application/json"
      })

      expect(response.status).to eq(400)
      expect(fake.violations).to eq(["missing headers: Idempotency-Key"])
    end

    it "answers 401 for a token signed with another key or expired" do
      forged = TimekeepingContracts.user_token(company_id: company_a, key: "another-key")
      expired = TimekeepingContracts.user_token(company_id: company_a, now: 2.minutes.ago)

      expect(request(:list_entries, token: forged).status).to eq(401)
      expect(request(:list_entries, token: expired).status).to eq(401)
    end
  end

  describe "reservation API" do
    let(:invoice) { 900 }
    let(:operation_id) { SecureRandom.uuid }

    def prepare(entry_ids, invoice_id: invoice, operation: operation_id, company_id: company_a, resolves: nil, kind: "save")
      request(:prepare, invoice_id:, operation_id: operation, key: operation, body: {
        "company_id" => company_id, "generation" => 3, "kind" => kind, "invoice_state" => "draft",
        "entry_ids" => entry_ids, "resolves" => resolves
      })
    end

    def resolve(outcome, invoice_id: invoice, operation: operation_id)
      request(outcome, invoice_id:, operation_id: operation, key: operation, body: { "generation" => 3 })
    end

    it "prepares with the entry facts line-item validation needs, and commits" do
      entry = create_entry

      prepared = prepare([entry["id"]])

      expect(prepared.body).to eq("status" => "prepared", "entries" => [entry.slice("id", "company_id", "project_id", "user_id", "duration", "work_date", "version")])
      expect(fake.holding(entry["id"])).to have_attributes(invoice_id: invoice, state: :provisional)
      expect(resolve(:commit).body).to eq("status" => "committed")
      expect(fake.holding(entry["id"])).to have_attributes(invoice_id: invoice, state: :committed)
    end

    it "refuses an entry already on another invoice (F1), of another company or unknown (L8)" do
      ours, theirs = create_entry, create_entry(company_id: company_b)
      prepare([ours["id"]], invoice_id: 800, operation: SecureRandom.uuid)

      refused = prepare([ours["id"], theirs["id"], 999_999])

      expect(refused.status).to eq(409)
      expect(refused.body["refused"]).to eq([
        { "entry_id" => ours["id"], "reason" => "on_other_invoice" },
        { "entry_id" => theirs["id"], "reason" => "wrong_company" },
        { "entry_id" => 999_999, "reason" => "not_found" }
      ])
      expect(fake.holding(ours["id"]).invoice_id).to eq(800)
    end

    it "hides held entries from candidates and frees them when a commit drops them" do
      kept_entry, dropped = create_entry, create_entry
      prepare([kept_entry["id"], dropped["id"]])
      resolve(:commit)

      candidates = -> { request(:candidates, query: { "client_id" => "1", "project_ids" => ["7"] }).body["entries"].pluck("id") }
      expect(candidates.call).to eq([])

      next_operation = SecureRandom.uuid
      prepare([kept_entry["id"]], operation: next_operation)
      resolve(:commit, operation: next_operation)

      expect(candidates.call).to eq([dropped["id"]])
      expect(fake.holding(kept_entry["id"]).state).to eq(:committed)
    end

    it "aborts only the operation's provisional holdings" do
      committed, provisional = create_entry, create_entry
      prepare([committed["id"]])
      resolve(:commit)
      second = SecureRandom.uuid

      prepare([committed["id"], provisional["id"]], operation: second)

      expect(resolve(:abort, operation: second).body).to eq("status" => "aborted")
      expect(fake.holding(committed["id"]).state).to eq(:committed)
      expect(fake.holding(provisional["id"])).to be_nil
    end

    it "answers a prepare, commit or abort after the operation is terminal with its receipt and no change" do
      entry = create_entry
      prepare([entry["id"]])
      resolve(:commit)

      expect(prepare([]).body).to eq("status" => "committed")
      expect(resolve(:abort).body).to eq("status" => "committed")
      expect(fake.holding(entry["id"]).state).to eq(:committed)
    end

    it "keeps a receipt for an abort of an unknown operation, and refuses its commit" do
      expect(resolve(:abort).body).to eq("status" => "aborted")
      expect(prepare([create_entry["id"]]).body).to eq("status" => "aborted")
      expect(resolve(:commit, operation: SecureRandom.uuid).status).to eq(404)
    end

    it "refuses a new operation while the invoice has an unresolved one, unless it carries its outcome" do
      entry = create_entry
      prepare([entry["id"]])
      later = SecureRandom.uuid

      refused = prepare([], operation: later, kind: "discard")
      settled = prepare([], operation: later, kind: "discard", resolves: { "operation_id" => operation_id, "outcome" => "committed" })

      expect(refused.status).to eq(409)
      expect(refused.body).to include("type" => TimekeepingContracts.problem_type("operation-unresolved"), "retryable" => true)
      expect(settled.body).to eq("status" => "prepared", "entries" => [])
      expect(resolve(:commit, operation: later).body).to eq("status" => "committed")
      expect(fake.holding(entry["id"])).to be_nil
    end

    it "refuses a prepare for another company than the token's" do
      refused = prepare([], company_id: company_b)

      expect(refused.status).to eq(403)
      expect(refused.body["type"]).to eq(TimekeepingContracts.problem_type("forbidden"))
    end

    it "answers a scripted failure, then serves the retry" do
      fake.fail_next(:prepare, status: 503, slug: "ownership-moving", retryable: true)
      entry = create_entry

      expect(prepare([entry["id"]]).status).to eq(503)
      expect(fake.holding(entry["id"])).to be_nil
      expect(prepare([entry["id"]]).body["status"]).to eq("prepared")
    end

    it "loses a response after applying it, so the retry finds the operation prepared" do
      fake.lose_next_response(:prepare)
      entry = create_entry

      expect { prepare([entry["id"]]) }.to raise_error(Faraday::TimeoutError)
      expect(fake.holding(entry["id"]).state).to eq(:provisional)
      expect(prepare([entry["id"]]).body["status"]).to eq("prepared")
    end
  end
end
