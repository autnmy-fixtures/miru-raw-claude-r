# frozen_string_literal: true

require "jwt"

# The user token every entry API call carries (docs/architecture/timekeeping-soa.md
# §6.1): an HS256 JWT signed with the shared token key, 60 s TTL. JWT checks
# the signature and expiry; the entry API contract's token_claims decides the
# rest, audience "timekeeping" included. The existing application's
# Timekeeping::UserToken signs it against the same definition.
module UserToken
  CLAIMS = "#/$defs/token_claims"

  # The verified claims of a Bearer authorization header. Nil when the header
  # is missing, the token is forged, expired or for another audience, its
  # claims break the contract, or no key is configured.
  def self.verify(authorization, key: Rails.configuration.x.timekeeping.token_key)
    token = authorization.to_s[/\ABearer (\S+)\z/, 1]
    return if token.nil? || key.blank?

    claims, = JWT.decode(token, key, true, algorithm: "HS256")
    claims if Contracts.errors(:entry_api, CLAIMS, claims).empty?
  rescue JWT::DecodeError
    nil
  end
end
