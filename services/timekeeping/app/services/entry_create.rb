# frozen_string_literal: true

# Entry create (docs/architecture/timekeeping-soa.md §5.2): W1 web and mobile,
# W3 CLI and MCP, W4 agent. The caller was authorized before the call (A1,
# A2 for W1 and W3, the project scope for W4, §6.2); what is checked here is
# what TimesheetEntry checks in the write today (§2.2): the model's rules,
# with the project's facts and the acting agent from the token.
#
# The token's company is the entry's (§6.3), and the token names the project
# the gateway resolved in it. An entry for any other project, or a project of
# another company, is refused as forbidden: the gateway never sends one.
#
# Two of today's checks are the gateway's, because they need the directory
# Timekeeping does not hold (§3.2): that the agent belongs to the company and
# that the entry's user is the agent's user (A10, W4 forces it), and that the
# user and project exist.
module EntryCreate
  # Answers [201, entry_response], or raises Problem::Raised with nothing
  # written.
  def self.call(attributes, claims)
    project = EntryCommand.project!(attributes.fetch("project_id"), claims)

    entry = Entry.new(attributes.merge("company_id" => claims.fetch("company_id"), "agent_id" => claims.dig("actor", "agent_id")))
    entry.project_facts = project
    raise Problem::Raised, EntryCommand.invalid(entry) unless EntryCommand.created?(entry, claims)

    [201, { "entry" => entry.to_contract }]
  end
end
