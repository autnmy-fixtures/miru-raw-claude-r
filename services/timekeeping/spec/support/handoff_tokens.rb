# frozen_string_literal: true

require "jwt"

# The handoff tool's service token (handoff_api.json service_token_claims),
# signed with the same test key UserTokens sets for request specs.
module HandoffTokens
  def handoff_token(key: UserTokens::TEST_KEY, now: Time.current, ttl: 60, **overrides)
    claims = { "sub" => "service:timekeeping-handoff", "aud" => "handoff", "iat" => now.to_i, "exp" => now.to_i + ttl }
    JWT.encode(claims.merge(overrides.transform_keys(&:to_s)), key, "HS256")
  end

  # The headers every handoff API call carries (handoff_api.json x-headers),
  # X-Ownership-Generation too when it names one.
  def handoff_headers(generation: nil, token: handoff_token)
    {
      "Authorization" => "Bearer #{token}", "X-Request-Id" => "handoff-1", "Content-Type" => "application/json",
      "X-Ownership-Generation" => generation&.to_s
    }.compact
  end
end

RSpec.configure { |config| config.include HandoffTokens }
