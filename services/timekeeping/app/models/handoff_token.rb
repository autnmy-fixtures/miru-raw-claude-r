# frozen_string_literal: true

require "jwt"

# The token the handoff tool presents to the handoff API
# (docs/architecture/timekeeping-soa.md §10.5, handoff_api.json): an HS256
# JWT signed with the shared token key (§6.1, §11.2), 60 s TTL. JWT checks
# the signature and expiry; the contract's service_token_claims decides the
# rest, audience "handoff" and subject the handoff tool. A user token, or the
# relay's, is not one.
module HandoffToken
  CLAIMS = "#/$defs/service_token_claims"

  # The verified claims of a Bearer authorization header. Nil when the header
  # is missing, the token is forged, expired, for another audience or subject,
  # its claims break the contract, or no key is configured.
  def self.verify(authorization, key: Rails.configuration.x.timekeeping.token_key)
    token = authorization.to_s[/\ABearer (\S+)\z/, 1]
    return if token.nil? || key.blank?

    claims, = JWT.decode(token, key, true, algorithm: "HS256")
    claims if Contracts.errors(:handoff_api, CLAIMS, claims).empty?
  rescue JWT::DecodeError
    nil
  end
end
