# frozen_string_literal: true

require "rails_helper"

# Invoice candidate selection (§5.2, §3.3 rule 1), provider side (§12.3): the
# kept, unbilled entries of the token's company (§6.3) in the projects the
# query names, that hold no active and no provisional reservation (§7.1), as
# entry_api.json states them.
RSpec.describe "Entry API candidates" do
  # The two seeded businesses (db/seeds.rb): Fork & Leaf Salads and Copper
  # Kettle Bakery, here by tenant id.
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:project_id) { 11 }

  def body = JSON.parse(response.body)

  def candidates(company_id, headers: entry_api_headers(company_id:, sub: "system", role: nil, writer: "invoice"), **query)
    get "/internal/v1/candidates", params: { client_id: "5", project_ids: [project_id.to_s] }.merge(query).compact, headers:
  end

  def candidate_ids = body.fetch("entries").pluck("id")

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  it "answers the kept, unbilled entries of the token's company in the named projects, as the contract states them" do
    ours = entry!(company_id: fork_and_leaf, project_id:)
    entry!(company_id: fork_and_leaf, project_id:, bill_status: "billed")
    entry!(company_id: fork_and_leaf, project_id:, bill_status: "non_billable")
    entry!(company_id: fork_and_leaf, project_id:, discarded_at: Time.current)
    entry!(company_id: fork_and_leaf, project_id: project_id + 1)
    theirs = entry!(company_id: copper_kettle, project_id:)

    candidates(fork_and_leaf)

    expect(response).to have_http_status(:ok)
    expect(contract_errors("entry_api", "#/$defs/candidates_response", body)).to be_empty
    expect(candidate_ids).to eq([ours.id])
    expect(body.fetch("entries").first).to eq(JSON.parse(ours.reload.to_contract.to_json))

    candidates(copper_kettle)

    expect(candidate_ids).to eq([theirs.id])
  end

  it "leaves out an entry an invoice holds, active or provisional, and keeps one only retained (L3, L4)" do
    free = entry!(company_id: fork_and_leaf, project_id:)
    retained = entry!(company_id: fork_and_leaf, project_id:)
      .tap { |entry| reservation!(entry, invoice_id: 3, disposition: "retained") }
    entry!(company_id: fork_and_leaf, project_id:).tap { |entry| reservation!(entry, invoice_id: 4) }
    entry!(company_id: fork_and_leaf, project_id:).tap { |entry| reservation!(entry, invoice_id: 5, edit_lock: false) }
    entry!(company_id: fork_and_leaf, project_id:).tap { |entry| reservation!(entry, invoice_id: 6, state: "provisional") }

    candidates(fork_and_leaf)

    expect(candidate_ids).to eq([free.id, retained.id])
    expect(body.fetch("entries").to_h { |entry| [entry["id"], entry["locked"]] }).to eq(free.id => false, retained.id => true)
  end

  it "narrows by users, excluded ids and an inclusive work-date range" do
    match = entry!(company_id: fork_and_leaf, project_id:, user_id: 3, work_date: Date.new(2026, 11, 2))
    on_to = entry!(company_id: fork_and_leaf, project_id:, user_id: 4, work_date: Date.new(2026, 11, 3))
    excluded = entry!(company_id: fork_and_leaf, project_id:, user_id: 3, work_date: Date.new(2026, 11, 2))
    entry!(company_id: fork_and_leaf, project_id:, user_id: 5, work_date: Date.new(2026, 11, 2))
    entry!(company_id: fork_and_leaf, project_id:, user_id: 3, work_date: Date.new(2026, 11, 1))
    entry!(company_id: fork_and_leaf, project_id:, user_id: 3, work_date: Date.new(2026, 11, 4))

    candidates(fork_and_leaf, user_ids: %w[3 4], exclude_ids: [excluded.id.to_s], from: "2026-11-02", to: "2026-11-03")

    expect(candidate_ids).to eq([match.id, on_to.id])
  end

  it "takes several projects at once" do
    first = entry!(company_id: fork_and_leaf, project_id:)
    second = entry!(company_id: fork_and_leaf, project_id: project_id + 1)
    entry!(company_id: fork_and_leaf, project_id: project_id + 2)

    candidates(fork_and_leaf, project_ids: [project_id.to_s, (project_id + 1).to_s])

    expect(candidate_ids).to eq([first.id, second.id])
  end

  # The search GenerateInvoice::NewLineItemsService runs today through
  # TimesheetEntry.pg_search: english stems, each word a prefix, every word
  # required, best rank first and then by id.
  describe "search_term" do
    let!(:prep) { entry!(company_id: fork_and_leaf, project_id:, note: "Salad prep for the lunch menu") }
    let!(:baking) { entry!(company_id: fork_and_leaf, project_id:, note: "Baking sourdough") }
    let!(:lunch) { entry!(company_id: fork_and_leaf, project_id:, note: "Lunch salads, lunch service, lunch prep") }
    let!(:silent) { entry!(company_id: fork_and_leaf, project_id:, note: nil) }

    {
      "a word prefix" => ["sal", -> { [prep, lunch] }],
      "an english stem" => ["bakes", -> { [baking] }],
      "every word of the term" => ["lunch prep", -> { [lunch, prep] }],
      "a term in any case" => ["SOURDOUGH", -> { [baking] }],
      "a word nothing matches" => ["invoice", -> { [] }]
    }.each do |name, (term, expected)|
      it "matches #{name}" do
        candidates(fork_and_leaf, search_term: term)

        expect(response).to have_http_status(:ok)
        expect(candidate_ids).to eq(instance_exec(&expected).map(&:id))
      end
    end

    it "orders by rank first: the note that repeats the word ranks above the earlier entry" do
      candidates(fork_and_leaf, search_term: "lunch")

      expect(prep.id).to be < lunch.id
      expect(candidate_ids).to eq([lunch.id, prep.id])
    end

    it "treats quotes, colons and question marks as spaces, as pg_search does, instead of failing the query" do
      candidates(fork_and_leaf, search_term: "salad's: prep?")

      expect(response).to have_http_status(:ok)
      expect(candidate_ids).to contain_exactly(prep.id, lunch.id)
    end

    it "is no search when blank" do
      candidates(fork_and_leaf, search_term: " ")

      expect(candidate_ids).to eq([prep, baking, lunch, silent].map(&:id))
    end
  end

  {
    "no project_ids" => { project_ids: nil },
    "no client_id" => { client_id: nil },
    "a parameter the contract does not list" => { selected_entries: %w[1] },
    "user_ids that are not a list" => { user_ids: "3" },
    "an id that is not one" => { exclude_ids: %w[0] },
    "a date that is not one" => { to: "2026-02-30" }
  }.each do |name, query|
    it "refuses #{name} as invalid-request" do
      candidates(fork_and_leaf, **query)

      expect_problem(400, "invalid-request")
    end
  end

  it "refuses a call without a valid token as unauthenticated, before reading anything" do
    entry!(company_id: fork_and_leaf, project_id:)

    candidates(fork_and_leaf, headers: { "X-Request-Id" => "req" })

    expect_problem(401, "unauthenticated")
  end

  it "refuses a call without X-Request-Id as invalid-request" do
    candidates(fork_and_leaf, headers: entry_api_headers(company_id: fork_and_leaf).except("X-Request-Id"))

    expect_problem(400, "invalid-request")
  end
end
