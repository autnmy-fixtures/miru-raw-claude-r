# frozen_string_literal: true

require "rails_helper"

# The token this application presents to Timekeeping
# (docs/architecture/timekeeping-soa.md §6.1), held to the entry API
# contract's token_claims.
RSpec.describe Timekeeping::UserToken do
  let(:company) { create(:company, timesheet_edit_days: 9) }
  let(:claims) { described_class.system_claims(company:, writer: "invoice", request_id: "req-1") }
  let(:now) { Time.zone.parse("2026-11-11 10:00:00") }

  it "signs system claims as an HS256 token for Timekeeping with a 60 s TTL" do
    travel_to(now) do
      token = described_class.sign(claims, key: TimekeepingContracts::TEST_TOKEN_KEY, now:)
      decoded = TimekeepingContracts.decode(token, key: TimekeepingContracts::TEST_TOKEN_KEY, audience: "timekeeping")

      expect(decoded).to eq(claims.merge("aud" => "timekeeping", "iat" => now.to_i, "exp" => now.to_i + 60))
      expect(decoded).to include("sub" => "system", "role" => nil, "timesheet_edit_days" => 9, "actor" => { "type" => "system", "agent_id" => nil })
    end
  end

  describe ".caller_claims (§6.1)" do
    let(:client) { create(:client, company:) }
    let(:project) { create(:project, client:, billable: false) }
    let(:user) do
      create(:user, current_workspace_id: company.id).tap do |user|
        create(:employment, company:, user:)
        user.add_role(:admin, company)
      end
    end

    it "carries the user's role in the company, its edit window and the project's reference facts" do
      claims = described_class.caller_claims(user:, company:, writer: "web", project:, request_id: "req-2")

      expect(claims).to eq(
        "sub" => "user:#{user.id}", "company_id" => company.id, "role" => "admin", "timesheet_edit_days" => 9,
        "actor" => { "type" => "user", "agent_id" => nil }, "writer" => "web", "request_id" => "req-2",
        "project" => { "id" => project.id, "company_id" => company.id, "kept" => true, "billable" => false }
      )
      expect { described_class.sign(claims, key: "key") }.not_to raise_error
    end

    it "acts as the agent a user is signed in through" do
      agent = create(:agent, company:, user:)

      claims = described_class.caller_claims(user:, company:, writer: "agent", project:, agent:, request_id: "req-3")

      expect(claims).to include("sub" => "user:#{user.id}", "actor" => { "type" => "agent", "agent_id" => agent.id })
    end

    it "carries no projects claim unless the command names its projects per row" do
      expect(described_class.caller_claims(user:, company:, writer: "web", project:, request_id: "req-5")).not_to have_key("projects")
    end

    it "carries each named project's reference facts once, as the projects claim (W5)" do
      other = create(:project, client:, billable: true)

      claims = described_class.caller_claims(user: nil, company:, writer: "import", projects: [project, other, project], request_id: "req-6")

      expect(claims).to include("project" => nil, "projects" => [
        { "id" => project.id, "company_id" => company.id, "kept" => true, "billable" => false },
        { "id" => other.id, "company_id" => company.id, "kept" => true, "billable" => true }
      ])
      expect { described_class.sign(claims, key: "key") }.not_to raise_error
    end

    it "is the system actor without a user, as Current.user == nil is today" do
      claims = described_class.caller_claims(user: nil, company:, writer: "web", project:, request_id: "req-4")

      expect(claims).to include("sub" => "system", "role" => nil, "actor" => { "type" => "system", "agent_id" => nil })
      expect(claims["project"]).to include("id" => project.id)
    end
  end

  it "never signs claims that break the contract" do
    expect { described_class.sign(claims.merge("writer" => "console"), key: "key") }
      .to raise_error(described_class::InvalidClaims, /writer/)
  end
end
