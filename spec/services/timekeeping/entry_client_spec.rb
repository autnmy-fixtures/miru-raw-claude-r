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

  it "is not configured without a URL or a token key" do
    expect { described_class.new(url: nil, token_key: "key") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_URL/)
    expect { described_class.new(url: "http://timekeeping.test", token_key: "") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_TOKEN_KEY/)
  end
end
