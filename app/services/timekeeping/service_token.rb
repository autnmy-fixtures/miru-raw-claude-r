# frozen_string_literal: true

require "jwt"

# The token the Timekeeping relay presents to the projection endpoint
# (docs/architecture/timekeeping-soa.md §5.4, §6.1): an HS256 JWT signed with
# the shared token key, 60 s TTL. JWT checks the signature and expiry; the
# entry snapshot contract's service_token_claims decides the rest, audience
# "projection" and subject the relay included.
module Timekeeping::ServiceToken
  CLAIMS = "#/$defs/service_token_claims"

  # The verified claims of a Bearer authorization header. Nil when the header
  # is missing, the token is forged, expired, for another audience or subject,
  # its claims break the contract, or no key is configured.
  def self.verify(authorization, key: Rails.configuration.x.timekeeping.token_key)
    token = authorization.to_s[/\ABearer (\S+)\z/, 1]
    return if token.nil? || key.blank?

    claims, = JWT.decode(token, key, true, algorithm: "HS256")
    claims if Timekeeping::Contracts.errors(:entry_snapshot, CLAIMS, claims).empty?
  rescue JWT::DecodeError
    nil
  end
end
