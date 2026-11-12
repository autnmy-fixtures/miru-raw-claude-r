# frozen_string_literal: true

require "rails_helper"

# §6.1: every entry API call carries the user token the existing
# application's gateway signs. Only a token signed with the shared key, for
# this audience, unexpired, whose claims the contract's token_claims allows,
# is accepted.
RSpec.describe UserToken do
  let(:key) { "shared-token-key" }
  let(:claims) { user_token_claims(company_id: 1) }

  def verify(token, key: self.key)
    described_class.verify("Bearer #{token}", key:)
  end

  it "answers the claims of a token signed with the shared key" do
    expect(verify(user_token(claims, key:))).to include("company_id" => 1, "sub" => "user:7", "aud" => "timekeeping")
  end

  it "accepts the system actor the existing application signs for imports and jobs" do
    system = claims.merge("sub" => "system", "role" => nil, "actor" => { "type" => "system", "agent_id" => nil }, "writer" => "import")

    expect(verify(user_token(system, key:))).to include("sub" => "system", "role" => nil)
  end

  {
    "signed with another key" => ->(spec) { spec.user_token(spec.claims, key: "another-key") },
    "expired" => ->(spec) { spec.user_token(spec.claims, key: spec.key, now: 2.minutes.ago) },
    "for another audience" => ->(spec) { spec.user_token(spec.claims.merge("aud" => "projection"), key: spec.key) },
    "without the tenant" => ->(spec) { spec.user_token(spec.claims.except("company_id"), key: spec.key) },
    "naming a writer the contract does not list" => ->(spec) { spec.user_token(spec.claims.merge("writer" => "cron"), key: spec.key) }
  }.each do |name, token|
    it "refuses a token #{name}" do
      expect(verify(token.call(self))).to be_nil
    end
  end

  it "refuses a missing or malformed header, and every token while no key is configured" do
    expect(described_class.verify(nil, key:)).to be_nil
    expect(described_class.verify(user_token(claims, key:), key:)).to be_nil
    expect(verify(user_token(claims, key:), key: nil)).to be_nil
  end
end
