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
  def self.system_claims(company:, writer:, request_id:, project: nil)
    {
      "sub" => "system", "company_id" => company.id, "role" => nil,
      "timesheet_edit_days" => company.timesheet_edit_days,
      "actor" => { "type" => "system", "agent_id" => nil },
      "writer" => writer, "project" => project_claim(project), "request_id" => request_id
    }
  end

  # The caller of one entry command (§6.1): the facts `authorize` and the
  # model's role checks read today (§2.2), resolved before the write. `user`
  # is today's Current.user, so nil is the system actor, exactly where the
  # model's checks skip today. A user signed in through an agent key acts as
  # that agent (W4), whose id Timekeeping sets on the entry.
  def self.caller_claims(user:, company:, writer:, request_id:, project: nil, agent: nil)
    return system_claims(company:, writer:, request_id:, project:) if user.nil?

    {
      "sub" => "user:#{user.id}", "company_id" => company.id, "role" => user.primary_role(company),
      "timesheet_edit_days" => company.timesheet_edit_days,
      "actor" => { "type" => agent ? "agent" : "user", "agent_id" => agent&.id },
      "writer" => writer, "project" => project_claim(project), "request_id" => request_id
    }
  end

  # The reference facts of the command's project (§6.1), from the catalogue
  # this application keeps.
  def self.project_claim(project)
    project && {
      "id" => project.id, "company_id" => project.client.company_id,
      "kept" => project.kept?, "billable" => project.billable
    }
  end
  private_class_method :project_claim
end
