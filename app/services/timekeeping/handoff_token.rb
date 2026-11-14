# frozen_string_literal: true

require "jwt"

# The token the handoff tool presents to Timekeeping's handoff API
# (handoff_api.json; docs/architecture/timekeeping-soa.md §10.5): an HS256
# JWT signed with the shared token key (§6.1, §11.2), 60 s TTL, audience
# "handoff", subject the handoff tool. No user acts here. The contract's
# service_token_claims is the one definition of its claims, so a token that
# breaks it is never signed.
module Timekeeping::HandoffToken
  CLAIMS = "#/$defs/service_token_claims"
  SUBJECT = "service:timekeeping-handoff"
  AUDIENCE = "handoff"
  TTL = 60.seconds

  # The claims break the contract, so the token would be refused anyway.
  class InvalidClaims < StandardError; end

  def self.sign(key:, now: Time.current)
    claims = { "sub" => SUBJECT, "aud" => AUDIENCE, "iat" => now.to_i, "exp" => (now + TTL).to_i }
    errors = Timekeeping::Contracts.errors(:handoff_api, CLAIMS, claims)
    raise InvalidClaims, "Timekeeping handoff token claims: #{errors.join('; ')}" if errors.any?

    JWT.encode(claims, key, "HS256")
  end
end
