# frozen_string_literal: true

require "jwt"

# The token this application presents to Timekeeping
# (docs/architecture/timekeeping-soa.md §6.1): an HS256 JWT signed with the
# shared token key, 60 s TTL, audience "timekeeping", carrying the facts
# resolved before the write. The entry API contract's token_claims is the
# one definition of those claims; a token that breaks it is never signed.
module Timekeeping::UserToken
  CLAIMS = "#/$defs/token_claims"
  AUDIENCE = "timekeeping"
  TTL = 60.seconds

  # The claims break the contract, so the token would be refused anyway.
  class InvalidClaims < StandardError; end

  def self.sign(claims, key:, now: Time.current)
    stamped = claims.merge("aud" => AUDIENCE, "iat" => now.to_i, "exp" => (now + TTL).to_i)
    errors = Timekeeping::Contracts.errors(:entry_api, CLAIMS, stamped)
    raise InvalidClaims, "Timekeeping token claims: #{errors.join('; ')}" if errors.any?

    JWT.encode(stamped, key, "HS256")
  end

  # The system actor of §6.1, today's `Current.user == nil`: no user, no
  # role, and the company's own edit window.
  def self.system_claims(company:, writer:, request_id:)
    {
      "sub" => "system", "company_id" => company.id, "role" => nil,
      "timesheet_edit_days" => company.timesheet_edit_days,
      "actor" => { "type" => "system", "agent_id" => nil },
      "writer" => writer, "project" => nil, "request_id" => request_id
    }
  end
end
