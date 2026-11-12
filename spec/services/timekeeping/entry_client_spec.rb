# frozen_string_literal: true

require "rails_helper"

# The `timekeeping` owner's entry API reads over HTTP
# (docs/architecture/timekeeping-soa.md §5.2, §3.3 rule 1), against the
# consumer-side fake of Timekeeping, which checks every request against the
# entry API contract (§12.3).
RSpec.describe Timekeeping::EntryClient do
  subject(:client) { described_class.new(url: TimekeepingContracts::FakeTimekeeping::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new.install! }
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }

  after { expect(fake.violations).to be_empty }

  def seed(company_id: company.id, project_id: 7, user_id: 3, **attributes)
    fake.seed_entry(company_id:, project_id:, user_id:, duration: 90.7, work_date: "2026-11-02", **attributes)
  end

  describe "#candidates" do
    it "answers the owner's candidates with the facts selection reads, duration and date as stored (§5.1)" do
      entry = seed(note: "Design review")

      expect(client.candidates(company:, client_id: 5, project_ids: [7])).to eq([described_class::Candidate.new(
        id: entry["id"], company_id: company.id, project_id: 7, user_id: 3, note: "Design review",
        work_date: Date.new(2026, 11, 2), duration: 90.7
      )])
      call = fake.calls.sole
      expect(call.input).to eq("client_id" => "5", "project_ids" => ["7"])
      expect(call.claims).to include("sub" => "system", "company_id" => company.id, "writer" => "invoice")
    end

    it "carries every filter in the contract's query (§5.2)" do
      kept = seed(user_id: 3, work_date: "2026-11-03", note: "Kickoff call")
      seed(user_id: 4, work_date: "2026-11-03", note: "Kickoff call")
      seed(user_id: 3, work_date: "2026-10-01", note: "Kickoff call")
      excluded = seed(user_id: 3, work_date: "2026-11-04", note: "Kickoff call")
      seed(user_id: 3, work_date: "2026-11-04", note: "Other")

      found = client.candidates(
        company:, client_id: 5, project_ids: [7, 8], user_ids: [3], exclude_ids: [excluded["id"]],
        work_dates: Date.new(2026, 11, 1)..Date.new(2026, 11, 30), search_term: "kickoff"
      )

      expect(found.map(&:id)).to eq([kept["id"]])
      expect(fake.calls.sole.input).to eq(
        "client_id" => "5", "project_ids" => %w[7 8], "user_ids" => ["3"], "exclude_ids" => [excluded["id"].to_s],
        "from" => "2026-11-01", "to" => "2026-11-30", "search_term" => "kickoff"
      )
    end

    it "reads only the token's tenant (§6.3)" do
      seed(company_id: other_company.id)

      expect(client.candidates(company:, client_id: 5, project_ids: [7])).to be_empty
    end

    it "makes no call for an empty id list, which selects nothing" do
      seed

      expect(client.candidates(company:, client_id: 5, project_ids: [])).to eq([])
      expect(client.candidates(company:, client_id: 5, project_ids: [7], user_ids: [])).to eq([])
      expect(fake.calls).to be_empty
    end

    it "raises Unavailable when Timekeeping cannot answer: a timeout or a 5xx" do
      fake.lose_next_response(:candidates)
      expect { client.candidates(company:, client_id: 5, project_ids: [7]) }.to raise_error(described_class::Unavailable, /candidates/)

      fake.fail_next(:candidates, status: 503, slug: "ownership-moving", retryable: true)
      expect { client.candidates(company:, client_id: 5, project_ids: [7]) }.to raise_error(described_class::Unavailable, /HTTP 503/)

      WebMock::API.stub_request(:get, %r{/internal/v1/candidates}).to_return(status: 502, body: "<html>Bad Gateway</html>")
      expect { client.candidates(company:, client_id: 5, project_ids: [7]) }.to raise_error(described_class::Unavailable, /HTTP 502/)
    end

    it "raises any other problem as it was answered" do
      fake.fail_next(:candidates, status: 403, slug: "forbidden", retryable: false)

      expect { client.candidates(company:, client_id: 5, project_ids: [7]) }.to raise_error(described_class::Problem) { |problem|
        expect(problem.type).to eq("forbidden")
      }
    end

    it "refuses an answer outside the contract" do
      WebMock::API.stub_request(:get, %r{/internal/v1/candidates}).to_return(status: 200, body: '{"entries":[{"id":1}]}')

      expect { client.candidates(company:, client_id: 5, project_ids: [7]) }
        .to raise_error(described_class::ContractViolation, /HTTP 200 is not an answer of the entry_api contract/)
    end
  end

  describe "entry reads (§3.3 rule 1, §5.2)" do
    let(:claims) do
      Timekeeping::UserToken.system_claims(company:, writer: "web", request_id: "req-9")
        .merge("sub" => "user:3", "role" => "employee", "actor" => { "type" => "user", "agent_id" => nil })
    end
    let(:november) { Date.new(2026, 11, 1)..Date.new(2026, 11, 30) }

    it "lists the user's kept entries in the dates with the caller's claims, the owner's entry as stored" do
      listed = seed(user_id: 3, work_date: "2026-11-03")
      seed(user_id: 4, work_date: "2026-11-03")
      seed(user_id: 3, work_date: "2026-10-31")
      seed(user_id: 3, work_date: "2026-11-04", discarded_at: "2026-11-05T10:00:00.000000Z")
      seed(company_id: other_company.id, user_id: 3, work_date: "2026-11-03")

      expect(client.list_entries(user_id: 3, work_dates: november, claims:)).to eq([fake.entry(listed["id"])])
      call = fake.calls.sole
      expect(call.input).to eq("user_id" => "3", "from" => "2026-11-01", "to" => "2026-11-30")
      expect(call.claims).to include("sub" => "user:3", "company_id" => company.id, "writer" => "web", "request_id" => "req-9")
    end

    it "lists the kept entries among ids, of the user when one is named (W2)" do
      mine = seed(user_id: 3)
      theirs = seed(user_id: 4)
      seed(user_id: 3)
      foreign = seed(company_id: other_company.id, user_id: 3)
      ids = [mine, theirs, foreign].pluck("id")

      expect(client.list_entries(ids:, claims:).pluck("id")).to eq([mine["id"], theirs["id"]])
      expect(client.list_entries(ids:, user_id: 3, claims:).pluck("id")).to eq([mine["id"]])
      expect(fake.calls.map(&:input)).to eq([{ "ids" => ids.map(&:to_s) }, { "ids" => ids.map(&:to_s), "user_id" => "3" }])
    end

    it "makes no call for an empty id list, which selects nothing" do
      seed

      expect(client.list_entries(ids: [], claims:)).to eq([])
      expect(fake.calls).to be_empty
    end

    it "follows next_cursor until the last page" do
      fake = TimekeepingContracts::FakeTimekeeping.new(list_page_size: 2).install!
      ids = Array.new(5) { fake.seed_entry(company_id: company.id, project_id: 7, user_id: 3, duration: 30.0, work_date: "2026-11-02")["id"] }

      expect(client.list_entries(user_id: 3, work_dates: november, claims:).pluck("id")).to eq(ids)
      expect(fake.calls.map { |call| call.input["cursor"] }).to eq([nil, "2", "4"])
      expect(fake.violations).to be_empty
    end

    it "shows one kept entry of the token's tenant, and answers not-found for any other (§6.3)" do
      shown = seed
      discarded = seed(discarded_at: "2026-11-05T10:00:00.000000Z")
      foreign = seed(company_id: other_company.id)

      expect(client.show_entry(shown["id"], claims:)).to eq(fake.entry(shown["id"]))
      [discarded, foreign].each do |entry|
        expect { client.show_entry(entry["id"], claims:) }.to raise_error(described_class::Problem) { |problem|
          expect([problem.status, problem.type]).to eq([404, "not-found"])
        }
      end
      expect(fake.calls.map(&:params)).to eq([shown, discarded, foreign].map { |entry| { "id" => entry["id"].to_s } })
    end

    it "raises Unavailable when Timekeeping cannot answer a read" do
      fake.lose_next_response(:list_entries)
      expect { client.list_entries(user_id: 3, work_dates: november, claims:) }.to raise_error(described_class::Unavailable, /list_entries/)

      fake.fail_next(:show_entry, status: 503, slug: "ownership-moving", retryable: true)
      expect { client.show_entry(1, claims:) }.to raise_error(described_class::Unavailable, /show_entry: HTTP 503/)
    end
  end

  describe "entry writes (§5.1, §5.2, §9.4)" do
    subject(:client) do
      described_class.new(
        url: TimekeepingContracts::FakeTimekeeping::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY,
        backoff: ->(seconds) { pauses << seconds }
      )
    end

    let(:pauses) { [] }
    let(:claims) do
      Timekeeping::UserToken.system_claims(company:, writer: "import", request_id: "req-7")
        .merge("sub" => "user:3", "role" => "admin", "actor" => { "type" => "user", "agent_id" => nil }, "writer" => "web")
    end
    let(:write) { described_class::Write.new(claims:, generation: 1, idempotency_key: "key-1") }
    let(:new_entry) { { "project_id" => 7, "user_id" => 3, "duration" => 90.7, "work_date" => "2026-11-02" } }

    it "creates, updates and discards, answering the owner's entry with the caller's claims and generation" do
      created = client.create_entry(new_entry, write:)
      updated = client.update_entry(created["id"], { "note" => "Edited" }, write: write.with(idempotency_key: "key-2"))
      discarded = client.discard_entry(created["id"], write: write.with(idempotency_key: "key-3"))

      expect(created).to include("company_id" => company.id, "duration" => 90.7, "version" => 1)
      expect(updated).to include("note" => "Edited", "version" => 2)
      expect(discarded["discarded_at"]).to be_present
      expect(fake.calls.map(&:operation)).to eq(%i[create_entry update_entry discard_entry])
      expect(fake.calls.map(&:claims)).to all(include("sub" => "user:3", "writer" => "web", "request_id" => "req-7"))
    end

    it "retries a lost response with the same key, so the owner replays its stored result (§9.4)" do
      fake.lose_next_response(:create_entry)

      created = client.create_entry(new_entry, write:)

      expect(fake.calls.map(&:operation)).to eq(%i[create_entry create_entry])
      expect(fake.entry(created["id"])).to eq(created)
      expect(fake.entry(created["id"] + 1)).to be_nil
      expect(pauses.size).to eq(1)
      expect(pauses).to all(be_between(0.05, 0.2))
    end

    it "makes at most three attempts, then raises Unavailable" do
      WebMock::API.stub_request(:post, %r{/internal/v1/entries\z}).to_return(status: 503, body: "")

      expect { client.create_entry(new_entry, write:) }.to raise_error(described_class::Unavailable, /create_entry: HTTP 503/)
      expect(WebMock).to have_requested(:post, %r{/internal/v1/entries\z}).times(3)
      expect(pauses.size).to eq(2)
    end

    it "does not retry a problem the owner answered" do
      fake.fail_next(:update_entry, status: 422, slug: "validation-failed", retryable: false, errors: { "duration" => ["can't be blank"] })
      entry = seed

      expect { client.update_entry(entry["id"], { "note" => "x" }, write:) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.errors]).to eq([422, "validation-failed", { "duration" => ["can't be blank"] }])
      }
      expect(fake.calls.size).to eq(1)
    end

    it "detaches an agent from the token company's entries, and answers the ids it changed (W6)" do
      named = seed(agent_id: 9)
      other_agent = seed(agent_id: 10)
      foreign = seed(company_id: other_company.id, agent_id: 9)

      expect(client.detach_agent(9, write:)).to eq([named["id"]])
      expect(fake.calls.sole).to have_attributes(operation: :detach_agent, params: include("agent_id" => "9"), input: {})
      expect(fake.entry(named["id"])).to include("agent_id" => nil, "version" => 2)
      expect([other_agent, foreign].map { |entry| fake.entry(entry["id"])["agent_id"] }).to eq([10, 9])
    end

    it "writes an import batch named by import id and batch number, and answers what it created (W5)" do
      answer = client.import_batch("41-run", 2, [new_entry, new_entry.merge("bill_status" => "billed")], write:)

      expect(answer).to eq("created_ids" => [1, 2], "failed_rows" => [])
      expect(fake.calls.sole).to have_attributes(operation: :import_batch, params: { "import_id" => "41-run", "n" => "2" })
      expect(fake.entry(2)).to include("company_id" => company.id, "bill_status" => "billed")
    end

    it "never sends a request the contract cannot carry" do
      expect { client.create_entry(new_entry.merge("duration" => nil), write:) }
        .to raise_error(described_class::Invalid, %r{create_entry: .*/entry/duration})
      expect(fake.calls).to be_empty
    end
  end

  it "is not configured without a URL or a token key" do
    expect { described_class.new(url: nil, token_key: "key") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_URL/)
    expect { described_class.new(url: "http://timekeeping.test", token_key: "") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_TOKEN_KEY/)
  end
end
