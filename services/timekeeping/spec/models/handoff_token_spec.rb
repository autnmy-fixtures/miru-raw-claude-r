# frozen_string_literal: true

require "rails_helper"

# handoff_api.json: only the handoff tool's service token, signed with the
# shared key, for audience "handoff", unexpired, is accepted. A user token or
# the relay's token is not one.
RSpec.describe HandoffToken do
  let(:key) { "shared-token-key" }

  def verify(token, key: self.key)
    described_class.verify("Bearer #{token}", key:)
  end

  it "answers the claims of the handoff tool's token" do
    expect(verify(handoff_token(key:))).to include("sub" => "service:timekeeping-handoff", "aud" => "handoff")
  end

  {
    "signed with another key" => ->(spec) { spec.handoff_token(key: "another-key") },
    "expired" => ->(spec) { spec.handoff_token(key: spec.key, now: 2.minutes.ago) },
    "for the projection, as the relay's is" => ->(spec) { spec.handoff_token(key: spec.key, aud: "projection", sub: "service:timekeeping-relay") },
    "of another subject" => ->(spec) { spec.handoff_token(key: spec.key, sub: "user:7") },
    "carrying a tenant" => ->(spec) { spec.handoff_token(key: spec.key, company_id: 1) },
    "that is a user token" => ->(spec) { spec.user_token(spec.user_token_claims(company_id: 1), key: spec.key) }
  }.each do |name, token|
    it "refuses a token #{name}" do
      expect(verify(token.call(self))).to be_nil
    end
  end

  it "refuses a missing or malformed header, and every token while no key is configured" do
    expect(described_class.verify(nil, key:)).to be_nil
    expect(described_class.verify(handoff_token(key:), key:)).to be_nil
    expect(verify(handoff_token(key:), key: nil)).to be_nil
  end
end
