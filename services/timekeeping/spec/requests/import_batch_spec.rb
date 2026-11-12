# frozen_string_literal: true

require "rails_helper"

# W5's Harvest import batch (§3.4, §5.2), provider side (§12.3): one mutating
# call, admitted under the carried generation (§10.1) and idempotent by
# import_id:batch_no, that creates each row in its own savepoint under
# TimesheetEntry's create rules, with the facts of the row's project from the
# token's `projects` (§6.1). A row the rules reject fails alone; the rest of
# the batch is kept, as today's savepoint per row keeps it. A billed row is
# created unbilled and then marked billed, as today (§1.3).
RSpec.describe "Entry API import batch" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }

  let(:billable_project) { { "id" => 11, "company_id" => fork_and_leaf, "kept" => true, "billable" => true } }
  let(:non_billable_project) { { "id" => 12, "company_id" => fork_and_leaf, "kept" => true, "billable" => false } }
  let(:projects) { [billable_project, non_billable_project] }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  # One Harvest row as the importer sends it (Imports::HarvestTimeEntriesImporter#entry_attributes).
  def row(**attributes)
    {
      "project_id" => 11, "user_id" => 7, "duration" => 75.0, "work_date" => "2026-01-02", "note" => "Imported",
      "bill_status" => "unbilled", "source" => "import", "source_metadata" => { "tool" => "harvest" }
    }.merge(attributes.transform_keys(&:to_s))
  end

  # The import job's token: the system actor as the import writer (§6.1).
  def mutating_headers(company_id: fork_and_leaf, key: "41-run:2", carried: generation, **claims)
    entry_api_headers(
      company_id:, sub: "system", role: nil, actor: { "type" => "system", "agent_id" => nil },
      writer: "import", project: nil, projects:, **claims
    ).merge("Idempotency-Key" => key, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json")
  end

  # The rows are positional and always an array, so they never fold into
  # **headers.
  def import(rows, path: "/internal/v1/imports/41-run/batches/2", **headers)
    post path, params: JSON.generate({ "rows" => rows }), headers: mutating_headers(**headers)
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

  it "creates every row in the token's company, in row order, and answers them as the contract states it" do
    import([row, row(project_id: 12, bill_status: "non_billable", user_id: 9)])

    expect(response).to have_http_status(:ok)
    expect(contract_errors("entry_api", "#/$defs/import_batch_response", body)).to be_empty
    first, second = Entry.order(:id).to_a
    expect(body).to eq("created_ids" => [first.id, second.id], "failed_rows" => [])
    expect(first.to_contract).to include(
      "company_id" => fork_and_leaf, "project_id" => 11, "user_id" => 7, "agent_id" => nil, "duration" => 75.0,
      "work_date" => "2026-01-02", "note" => "Imported", "bill_status" => "unbilled", "review_status" => "not_required",
      "source" => "import", "source_metadata" => { "tool" => "harvest" }, "locked" => false, "version" => 1
    )
    expect(second).to have_attributes(project_id: 12, user_id: 9, bill_status: "non_billable")
  end

  it "writes one create audit row as the system import writer and one outbox snapshot per row (§3.4)" do
    import([row])

    entry = Entry.sole
    expect(entry.audits.sole).to have_attributes(
      company_id: fork_and_leaf, action: "create", version: 1, actor: "system", agent_id: nil,
      writer: "import", request_id: "req-#{fork_and_leaf}", audited_changes: entry.to_contract.slice(*Entry::AUDITED)
    )
    outbox = entry.outbox_snapshots.sole
    expect(outbox).to have_attributes(version: 1, request_id: "req-#{fork_and_leaf}")
    expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", outbox.snapshot)).to be_empty
    expect(outbox.snapshot).to eq(OutboxSnapshot.of(entry))
  end

  it "creates a billed row unbilled and then marks it billed, as today's create! then update! (§1.3)" do
    import([row(note: "Invoiced", bill_status: "billed")])

    expect(response).to have_http_status(:ok)
    entry = Entry.sole
    expect(body).to eq("created_ids" => [entry.id], "failed_rows" => [])
    expect(entry).to have_attributes(bill_status: "billed", version: 2)
    expect(entry.audits.order(:version).map { |audit| [audit.action, audit.version, audit.audited_changes["bill_status"]] })
      .to eq([["create", 1, "unbilled"], ["update", 2, %w[unbilled billed]]])
    expect(entry.outbox_snapshots.order(:id).map { |outbox| [outbox.version, outbox.snapshot.dig("data", "bill_status")] })
      .to eq([[1, "unbilled"], [2, "billed"]])
  end

  it "takes bill_status from the row's project when the row sets none, as the model does" do
    import([row.except("bill_status"), row(project_id: 12).except("bill_status")])

    expect(Entry.order(:id).pluck(:bill_status)).to eq(%w[unbilled non_billable])
  end

  describe "a row the rules reject fails alone; the rest of the batch is kept" do
    it "answers each rejected row by its index, with the model's errors by attribute, in row order" do
      import([row(duration: 7_000_000), row, row(project_id: 12, bill_status: "unbilled")])

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/import_batch_response", body)).to be_empty
      kept = Entry.sole
      expect(body).to eq(
        "created_ids" => [kept.id],
        "failed_rows" => [
          { "index" => 0, "errors" => { "duration" => ["must be less than or equal to 6000000"] } },
          { "index" => 2, "errors" => { "base" => ["You can't create an unbilled entry for non-billable projects"] } }
        ]
      )
      expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([1, 1, 1])
    end

    it "fails a billed row on a non-billable project at its create, writing nothing for it" do
      import([row(project_id: 12, bill_status: "billed")])

      expect(body).to eq(
        "created_ids" => [],
        "failed_rows" => [{ "index" => 0, "errors" => { "base" => ["You can't create an unbilled entry for non-billable projects"] } }]
      )
      expect([Entry.count, EntryAudit.count, OutboxSnapshot.count]).to eq([0, 0, 0])
    end
  end

  describe "the rows' projects (§6.1, §6.3)" do
    it "refuses the whole batch when a row names a project the token does not, writing nothing" do
      import([row, row(project_id: 13)])

      expect_problem(403, "forbidden")
      expect(body.fetch("detail")).to include("project 13")
      expect_nothing_written
    end

    it "refuses a token project of another company, writing nothing" do
      import([row], projects: [billable_project.merge("company_id" => copper_kettle)])

      expect_problem(403, "forbidden")
      expect_nothing_written
    end

    it "refuses a token with no projects claim, writing nothing" do
      headers = mutating_headers
      claims = user_token_claims(
        company_id: fork_and_leaf, sub: "system", role: nil, actor: { "type" => "system", "agent_id" => nil },
        writer: "import", project: nil
      )
      headers["Authorization"] = "Bearer #{user_token(claims)}"

      post "/internal/v1/imports/41-run/batches/2", params: JSON.generate({ "rows" => [row] }), headers: headers

      expect_problem(403, "forbidden")
      expect_nothing_written
    end

    it "creates the rows of another company in that company only (§6.3)" do
      import([row], company_id: copper_kettle, projects: [billable_project.merge("company_id" => copper_kettle)])

      expect(response).to have_http_status(:ok)
      expect(Entry.sole.company_id).to eq(copper_kettle)
    end
  end

  describe "the contract (§5.2)" do
    it "refuses an empty batch, one over 500 rows, a row missing a required field and an extra key" do
      import([])
      expect_problem(400, "invalid-request")

      import(Array.new(501) { row })
      expect_problem(400, "invalid-request")

      import([row.except("work_date")])
      expect_problem(400, "invalid-request")

      post "/internal/v1/imports/41-run/batches/2", params: JSON.generate({ "rows" => [row], "extra" => true }), headers: mutating_headers
      expect_problem(400, "invalid-request")

      expect_nothing_written
    end

    it "takes a batch of exactly 500 rows" do
      import(Array.new(500) { row })

      expect(body.fetch("created_ids").size).to eq(500)
    end

    it "has no batch 0" do
      import([row], path: "/internal/v1/imports/41-run/batches/0")

      expect_problem(404, "not-found")
      expect_nothing_written
    end
  end

  describe "admission (§10.1)" do
    it "refuses a stale generation and a moving owner, writing nothing" do
      import([row], carried: generation - 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "frozen")
      import([row])
      expect_problem(503, "ownership-moving")
      expect(body.fetch("retryable")).to be(true)

      expect_nothing_written
    end
  end

  describe "idempotency by import_id:batch_no (§3.4, §9.4)" do
    it "replays the stored answer for the same batch, writing nothing more" do
      import([row, row(duration: 7_000_000)])
      first = body

      import([row, row(duration: 7_000_000)])

      expect(response).to have_http_status(:ok)
      expect(body).to eq(first)
      expect([Entry.count, EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([1, 1, 1, 1])
    end

    it "refuses the same key for other rows, or for another batch's path" do
      import([row])

      import([row(note: "Something else")])
      expect_problem(409, "idempotency-conflict")

      import([row], path: "/internal/v1/imports/41-run/batches/3")
      expect_problem(409, "idempotency-conflict")

      expect(Entry.count).to eq(1)
    end
  end
end
