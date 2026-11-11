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

  it "never signs claims that break the contract" do
    expect { described_class.sign(claims.merge("writer" => "console"), key: "key") }
      .to raise_error(described_class::InvalidClaims, /writer/)
  end
end
