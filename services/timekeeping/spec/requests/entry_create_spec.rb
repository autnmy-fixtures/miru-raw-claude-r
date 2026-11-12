# frozen_string_literal: true

require "rails_helper"

# Entry create (§5.2), provider side (§12.3): one mutating call, admitted
# under the carried generation (§10.1), that writes the entry, its audit row,
# its outbox snapshot and its idempotency receipt in one transaction (§3.4),
# or nothing. The rules are TimesheetEntry's (§2.1, §6.2), with the project's
# facts and the acting agent from the token.
RSpec.describe "Entry API create" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }

  let(:billable_project) { { "id" => 11, "company_id" => fork_and_leaf, "kept" => true, "billable" => true } }
  let(:non_billable_project) { { "id" => 12, "company_id" => fork_and_leaf, "kept" => true, "billable" => false } }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  def new_entry(**attributes)
    { "project_id" => 11, "user_id" => 7, "duration" => 90.7, "work_date" => "2026-11-02", "note" => "Prep" }
      .merge(attributes.transform_keys(&:to_s))
  end

  def mutating_headers(company_id: fork_and_leaf, key: "key-1", carried: generation, project: billable_project, **claims)
    entry_api_headers(company_id:, project:, **claims).merge(
      "Idempotency-Key" => key, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json"
    )
  end

  def create(entry = new_entry, **headers)
    post "/internal/v1/entries", params: JSON.generate({ "entry" => entry }), headers: mutating_headers(**headers)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  def expect_nothing_written
    expect([Entry.count, EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([0, 0, 0, 0])
  end

  it "creates the entry in the token's company and answers it as the contract states it" do
    create

    expect(response).to have_http_status(:created)
    expect(contract_errors("entry_api", "#/$defs/entry_response", body)).to be_empty
    entry = Entry.sole
    expect(body.fetch("entry")).to eq(entry.to_contract)
    expect(body.fetch("entry")).to include(
      "company_id" => fork_and_leaf, "project_id" => 11, "user_id" => 7, "agent_id" => nil, "duration" => 90.7,
      "work_date" => "2026-11-02", "note" => "Prep", "bill_status" => "unbilled", "review_status" => "not_required",
      "source" => "manual", "locked" => false, "version" => 1
    )
  end

  it "writes one audit row and one outbox snapshot with the entry (§3.4)" do
    create

    entry = Entry.sole
    expect(entry.audits.sole).to have_attributes(
      company_id: fork_and_leaf, action: "create", version: 1, actor: "user:7", agent_id: nil,
      writer: "web", request_id: "req-#{fork_and_leaf}",
      audited_changes: entry.to_contract.slice(*Entry::AUDITED)
    )
    outbox = entry.outbox_snapshots.sole
    expect(outbox).to have_attributes(company_id: fork_and_leaf, version: 1, request_id: "req-#{fork_and_leaf}")
    expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", outbox.snapshot)).to be_empty
    expect(outbox.snapshot).to eq(
      "type" => "timekeeping.entry_snapshot.v1", "entry_id" => entry.id, "version" => 1, "company_id" => fork_and_leaf,
      "data" => entry.to_contract.except("id", "company_id", "version")
    )
  end

  it "takes bill_status from the project when the writer sets none" do
    create(new_entry(project_id: 12), project: non_billable_project)

    expect(response).to have_http_status(:created)
    expect(body.dig("entry", "bill_status")).to eq("non_billable")
  end

  it "applies A10 to an agent's entry: pending review, the agent from the token, the source rewritten to mcp" do
    create(
      new_entry(source: "cli", source_metadata: { "mcp_server" => " miru ", "other" => "dropped" }, proof_metadata: { "run" => " 42 ", "blank" => " " }),
      actor: { "type" => "agent", "agent_id" => 5 }, writer: "agent"
    )

    expect(response).to have_http_status(:created)
    expect(body.fetch("entry")).to include(
      "agent_id" => 5, "review_status" => "pending_review", "source" => "mcp",
      "source_metadata" => { "mcp_server" => "miru" }, "proof_metadata" => { "run" => "42" }
    )
    expect(Entry.sole.audits.sole).to have_attributes(agent_id: 5, writer: "agent")
  end

  describe "the model's rules, answered as validation-failed with today's messages" do
    it "refuses a billed entry" do
      create(new_entry(bill_status: "billed"))

      expect_problem(422, "validation-failed")
      expect(body.fetch("errors")).to eq("timesheet_entry" => ["You can't create a billed timesheet entry"])
      expect_nothing_written
    end

    it "refuses an unbilled entry on a non-billable project" do
      create(new_entry(project_id: 12, bill_status: "unbilled"), project: non_billable_project)

      expect_problem(422, "validation-failed")
      expect(body.fetch("errors")).to eq("base" => ["You can't create an unbilled entry for non-billable projects"])
      expect_nothing_written
    end

    it "refuses a duration out of range and a proof URL too long, each by attribute in the model's order" do
      create(new_entry(duration: 6_000_000.5, proof_url: "x" * 2001))

      expect_problem(422, "validation-failed")
      expect(body.fetch("errors")).to eq(
        "duration" => ["must be less than or equal to 6000000"],
        "proof_url" => ["is too long (maximum is 2000 characters)"]
      )
      expect_nothing_written
    end
  end

  describe "tenant and project (§6.3)" do
    it "refuses a project other than the token's, and the token's project of another company" do
      create(new_entry(project_id: 99))
      expect_problem(403, "forbidden")

      create(new_entry, project: billable_project.merge("company_id" => copper_kettle))
      expect_problem(403, "forbidden")

      create(new_entry, project: nil)
      expect_problem(403, "forbidden")

      expect_nothing_written
    end
  end

  describe "admission (§10.1)" do
    it "refuses a stale generation and a moving owner, writing nothing" do
      create(carried: generation - 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "closed")
      create
      expect_problem(503, "ownership-moving")
      expect(body.fetch("retryable")).to be(true)

      expect_nothing_written
    end

    it "refuses every write while Timekeeping does not own the entries" do
      Ownership.current.update!(owner: "monolith")

      create
      expect_problem(409, "stale-generation")
      expect_nothing_written
    end

    it "requires the mutating headers and a generation that is one" do
      post "/internal/v1/entries", params: JSON.generate({ "entry" => new_entry }),
        headers: mutating_headers.except("Idempotency-Key")
      expect_problem(400, "invalid-request")
      expect(body.fetch("detail")).to include("Idempotency-Key")

      create(carried: "three")
      expect_problem(400, "invalid-request")

      create(carried: -1)
      expect_problem(400, "invalid-request")

      expect_nothing_written
    end
  end

  describe "idempotency receipts (§9.4)" do
    it "replays the stored answer for the same key and the same request, writing nothing more" do
      create
      first = body

      create

      expect(response).to have_http_status(:created)
      expect(body).to eq(first)
      expect([Entry.count, EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([1, 1, 1, 1])
    end

    it "refuses the same key for another request" do
      create

      create(new_entry(note: "Something else"))

      expect_problem(409, "idempotency-conflict")
      expect(Entry.count).to eq(1)
    end

    it "keeps a key per tenant: another company's same key is its own call" do
      create
      create(new_entry, company_id: copper_kettle, project: billable_project.merge("company_id" => copper_kettle))

      expect(response).to have_http_status(:created)
      expect(Entry.pluck(:company_id)).to contain_exactly(fork_and_leaf, copper_kettle)
    end

    it "stores no receipt for a refusal, so the retry is decided afresh" do
      Ownership.current.update!(state: "closed")
      create
      expect_problem(503, "ownership-moving")

      Ownership.current.update!(state: "open")
      create

      expect(response).to have_http_status(:created)
    end
  end

  it "refuses a body the contract does not allow" do
    create(new_entry.except("work_date"))

    expect_problem(400, "invalid-request")
    expect_nothing_written
  end
end
