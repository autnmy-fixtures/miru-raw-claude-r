# frozen_string_literal: true

require "rails_helper"

# The entry API's reads (§5.2, §3.3 rule 1), provider side (§12.3): list and
# show answer only the kept entries of the token's company (§6.3), as
# entry_api.json states them, to a caller carrying a valid user token and the
# headers every call carries.
RSpec.describe "Entry API reads" do
  # The two seeded businesses (db/seeds.rb): Fork & Leaf Salads and Copper
  # Kettle Bakery, here by tenant id.
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }

  def body = JSON.parse(response.body)

  def list(company_id, **query)
    get "/internal/v1/entries", params: query, headers: entry_api_headers(company_id:)
  end

  def show(company_id, id, headers: entry_api_headers(company_id:))
    get "/internal/v1/entries/#{id}", headers:
  end

  def listed_ids = body.fetch("entries").pluck("id")

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  describe "GET /internal/v1/entries" do
    it "answers the kept entries of the token's company only, as the contract states them" do
      ours = entry!(company_id: fork_and_leaf)
      locked = entry!(company_id: fork_and_leaf).tap { |entry| reservation!(entry, invoice_id: 3) }
      entry!(company_id: fork_and_leaf, discarded_at: Time.current)
      theirs = entry!(company_id: copper_kettle)

      list(fork_and_leaf)

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/entry_list_response", body)).to be_empty
      expect(listed_ids).to contain_exactly(ours.id, locked.id)
      expect(body.fetch("entries").to_h { |entry| [entry["id"], entry["locked"]] }).to eq(ours.id => false, locked.id => true)
      expect(body.fetch("next_cursor")).to be_nil

      list(copper_kettle)

      expect(listed_ids).to eq([theirs.id])
    end

    it "narrows by user, ids, projects and an inclusive work-date range" do
      match = entry!(company_id: fork_and_leaf, user_id: 3, project_id: 7, work_date: Date.new(2026, 11, 2))
      on_from = entry!(company_id: fork_and_leaf, user_id: 3, project_id: 7, work_date: Date.new(2026, 11, 1))
      entry!(company_id: fork_and_leaf, user_id: 4, project_id: 7, work_date: Date.new(2026, 11, 2))
      entry!(company_id: fork_and_leaf, user_id: 3, project_id: 8, work_date: Date.new(2026, 11, 2))
      entry!(company_id: fork_and_leaf, user_id: 3, project_id: 7, work_date: Date.new(2026, 11, 3))
      theirs = entry!(company_id: copper_kettle, user_id: 3, project_id: 7, work_date: Date.new(2026, 11, 2))

      list(fork_and_leaf, user_id: "3", project_ids: %w[7], from: "2026-11-01", to: "2026-11-02")
      expect(listed_ids).to contain_exactly(match.id, on_from.id)

      list(fork_and_leaf, ids: [match.id.to_s, theirs.id.to_s])
      expect(listed_ids).to eq([match.id])
    end

    it "pages with a cursor until a null next_cursor" do
      stub_const("EntryList::PAGE_SIZE", 2)
      ids = Array.new(5) { entry!(company_id: fork_and_leaf).id }

      pages = []
      cursor = nil
      loop do
        list(fork_and_leaf, **{ cursor: }.compact)
        expect(contract_errors("entry_api", "#/$defs/entry_list_response", body)).to be_empty
        pages << listed_ids
        break unless (cursor = body.fetch("next_cursor"))
      end

      expect(pages.map(&:size)).to eq([2, 2, 1])
      expect(pages.flatten).to eq(ids)
    end

    it "keeps a page stable when an entry is written between pages" do
      stub_const("EntryList::PAGE_SIZE", 2)
      first, second, third = Array.new(3) { entry!(company_id: fork_and_leaf).id }

      list(fork_and_leaf)
      cursor = body.fetch("next_cursor")
      added = entry!(company_id: fork_and_leaf).id
      list(fork_and_leaf, cursor:)

      expect([first, second]).to all(be < third)
      expect(listed_ids).to eq([third, added])
    end

    {
      "a parameter the contract does not list" => { tenant: "2" },
      "ids that are not a list" => { ids: "1" },
      "an id that is not one" => { user_id: "0" },
      "a date that is not one" => { from: "2026-13-01" }
    }.each do |name, query|
      it "refuses #{name} as invalid-request" do
        list(fork_and_leaf, **query)

        expect_problem(400, "invalid-request")
      end
    end

    it "refuses a cursor it did not answer as invalid-request" do
      list(fork_and_leaf, cursor: "page-2")

      expect_problem(400, "invalid-request")
    end
  end

  describe "GET /internal/v1/entries/{id}" do
    it "answers one kept entry of the token's company, as the contract states it" do
      entry = entry!(company_id: fork_and_leaf).tap { |held| reservation!(held, invoice_id: 3, disposition: "retained") }

      show(fork_and_leaf, entry.id)

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/entry_response", body)).to be_empty
      expect(body.fetch("entry")).to include("id" => entry.id, "company_id" => fork_and_leaf, "version" => 1, "locked" => true)
    end

    it "answers not-found for another company's entry, a discarded one and one that does not exist" do
      theirs = entry!(company_id: copper_kettle)
      discarded = entry!(company_id: fork_and_leaf, discarded_at: Time.current)

      [theirs.id, discarded.id, discarded.id + 100].each do |id|
        show(fork_and_leaf, id)

        expect_problem(404, "not-found")
      end
    end

    it "answers not-found for an id that can name no entry" do
      show(fork_and_leaf, "abc")

      expect_problem(404, "not-found")
    end
  end

  describe "authentication and headers" do
    let!(:entry) { entry!(company_id: fork_and_leaf) }

    {
      "no token" => nil,
      "a token signed with another key" => ->(spec) { "Bearer #{spec.user_token(spec.user_token_claims(company_id: 1), key: 'other')}" },
      "an expired token" => ->(spec) { "Bearer #{spec.user_token(spec.user_token_claims(company_id: 1), now: 2.minutes.ago)}" }
    }.each do |name, authorization|
      it "refuses #{name} as unauthenticated, before reading anything" do
        headers = { "X-Request-Id" => "req" }
        headers["Authorization"] = authorization.call(self) if authorization

        show(fork_and_leaf, entry.id, headers:)
        expect_problem(401, "unauthenticated")

        get("/internal/v1/entries", headers:)
        expect_problem(401, "unauthenticated")
      end
    end

    it "refuses a call without X-Request-Id as invalid-request" do
      show(fork_and_leaf, entry.id, headers: entry_api_headers(company_id: fork_and_leaf).except("X-Request-Id"))

      expect_problem(400, "invalid-request")
      expect(body.fetch("detail")).to eq("missing headers: X-Request-Id")
    end
  end
end
