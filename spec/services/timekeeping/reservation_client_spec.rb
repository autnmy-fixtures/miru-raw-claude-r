# frozen_string_literal: true

require "rails_helper"

# The `timekeeping` owner's commit and abort over HTTP
# (docs/architecture/timekeeping-soa.md §5.3), against the consumer-side fake
# of Timekeeping, which checks every request against the reservation API
# contract (§12.3).
RSpec.describe Timekeeping::ReservationClient do
  include TimekeepingContracts::ReservationDriver

  subject(:client) { described_class.new(url: TimekeepingContracts::FakeTimekeeping::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 4).install! }
  let(:company) { create(:company) }
  let(:entry) { fake.seed_entry(company_id: company.id, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02") }
  let(:intent) do
    Timekeeping::InvoiceOperation.new(
      operation_id: SecureRandom.uuid, invoice_id: 812, company_id: company.id, kind: "save", entry_ids: [entry["id"]], generation: 4
    )
  end

  after { expect(fake.violations).to be_empty }

  describe "#prepare" do
    it "prepares the intent's desired set and answers the prepared entries (§5.3)" do
      answer = client.prepare(intent, invoice_state: :draft, resolves: nil)

      expect(answer).to eq(described_class::Prepared.new(entries: [described_class::PreparedEntry.new(
        id: entry["id"], company_id: company.id, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02", version: 1
      )]))
      expect(fake.calls.sole.input).to eq(
        "company_id" => company.id, "generation" => 4, "kind" => "save", "invoice_state" => "draft",
        "entry_ids" => [entry["id"]], "resolves" => nil
      )
      expect(fake.holding(entry["id"]).state).to eq(:provisional)
    end

    it "answers the stored receipt of an operation already terminal" do
      prepare_in_timekeeping(intent)
      client.commit(intent)

      expect(client.prepare(intent, invoice_state: :draft, resolves: nil)).to eq(described_class::Receipt.new(status: "committed"))
    end

    it "carries resolves, which settles the invoice's earlier operation first" do
      earlier = intent.dup.tap { |copy| copy.operation_id = SecureRandom.uuid }
      prepare_in_timekeeping(earlier)

      client.prepare(intent, invoice_state: :non_draft, resolves: { "operation_id" => earlier.operation_id, "outcome" => "aborted" })

      expect(client.commit(earlier)).to eq(described_class::Receipt.new(status: "aborted"))
    end

    it "raises a refusal with every refused entry and its reason (F1, L8)" do
      other_company = create(:company)
      foreign = fake.seed_entry(company_id: other_company.id, project_id: 8, user_id: 4, duration: 30.0, work_date: "2026-11-03")
      intent.entry_ids = [entry["id"], foreign["id"]]

      expect { client.prepare(intent, invoice_state: :draft, resolves: nil) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.retryable]).to eq([409, "reservation-refused", false])
        expect(problem.refused).to eq([TimekeepingReservations::Refusal.new(entry_id: foreign["id"], reason: :wrong_company)])
      }
    end
  end

  it "commits a prepared operation and answers Timekeeping's receipt" do
    prepare_in_timekeeping(intent)

    expect(client.commit(intent)).to eq(described_class::Receipt.new(status: "committed"))
    expect(fake.holding(entry["id"]).state).to eq(:committed)
  end

  it "aborts an operation Timekeeping never saw, and answers the no-op receipt (§9.3)" do
    expect(client.abort(intent)).to eq(described_class::Receipt.new(status: "aborted"))
  end

  it "answers the stored receipt when the operation is already terminal" do
    prepare_in_timekeeping(intent)
    client.abort(intent)

    expect(client.commit(intent)).to eq(described_class::Receipt.new(status: "aborted"))
  end

  it "signs a 60 s system token for the intent's company" do
    client.abort(intent)

    expect(fake.calls.last.claims).to include(
      "sub" => "system", "aud" => "timekeeping", "company_id" => company.id, "role" => nil, "writer" => "invoice", "project" => nil
    )
    expect(fake.calls.last.claims.values_at("exp", "iat").reduce(:-)).to eq(60)
  end

  it "raises the problem Timekeeping answers" do
    expect { client.commit(intent) }.to raise_error(described_class::Problem, /404 not-found/) do |problem|
      expect([problem.status, problem.type, problem.retryable]).to eq([404, "not-found", false])
    end
  end

  it "raises a stale generation as a problem, not as a receipt" do
    fake.generation = 5

    expect { client.abort(intent) }.to raise_error(described_class::Problem) { |problem| expect(problem.type).to eq("stale-generation") }
  end

  it "raises a lost response as a transport error" do
    fake.lose_next_response(:abort)

    expect { client.abort(intent) }.to raise_error(Faraday::TimeoutError)
  end

  it "raises an answer outside the contract" do
    WebMock::API.stub_request(:post, %r{/abort\z}).to_return(status: 502, body: "<html>Bad Gateway</html>")

    expect { client.abort(intent) }.to raise_error(described_class::ContractViolation, /HTTP 502/)
  end

  it "refuses to be built without Timekeeping's URL or the shared key" do
    expect { described_class.new(url: nil, token_key: "key") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_URL/)
    expect { described_class.new(url: "http://timekeeping.test", token_key: "") }.to raise_error(described_class::NotConfigured, /TIMEKEEPING_TOKEN_KEY/)
  end
end
