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
    project = claims.fetch("project")
    refuse_project!(attributes, claims) unless own_project?(project, attributes, claims)

    entry = Entry.new(attributes.merge("company_id" => claims.fetch("company_id"), "agent_id" => claims.dig("actor", "agent_id")))
    entry.project_facts = project
    raise Problem::Raised, invalid(entry) unless entry.save(context: Entry::CREATE)

    EntryChange.record!(entry, action: "create", audited_changes: entry.to_contract.slice(*Entry::AUDITED), claims:)
    [201, { "entry" => entry.to_contract }]
  end

  def self.own_project?(project, attributes, claims)
    project.present? && project.fetch("id") == attributes.fetch("project_id") && project.fetch("company_id") == claims.fetch("company_id")
  end
  private_class_method :own_project?

  def self.refuse_project!(attributes, claims)
    raise Problem::Raised, Problem.new(
      slug: "forbidden", status: 403,
      detail: "project #{attributes.fetch('project_id')} is not the token's project in company #{claims.fetch('company_id')}"
    )
  end
  private_class_method :refuse_project!

  # validation-failed with the model's errors by attribute, in the model's
  # order, which the gateway answers as today's message (§5.1).
  def self.invalid(entry)
    Problem.new(
      slug: "validation-failed", status: 422, detail: entry.errors.full_messages.to_sentence,
      errors: entry.errors.to_hash.transform_keys(&:to_s)
    )
  end
  private_class_method :invalid
end
