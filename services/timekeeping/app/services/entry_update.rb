# frozen_string_literal: true

# Entry update (docs/architecture/timekeeping-soa.md §5.2): W1 web and
# mobile, W3 CLI and MCP. In the order the existing application checks them
# today (§2.2, §6.2):
#
# 1. A3-A5 against the entry as it stands, held FOR UPDATE (EntryPolicy);
# 2. the project the entry will have is the one the token names, in the
#    token's company (§6.3); the gateway always sends it;
# 3. TimesheetEntry's update rules, in Entry's UPDATE context, with the
#    project's facts and the caller's role from the token: A10's review
#    status, the metadata normalized and the source inferred, the field
#    checks, an unbilled entry on a non-billable project, and the edit lock,
#    which stops employees only (L1).
#
# A refusal answers its problem with nothing written.
module EntryUpdate
  # Answers [200, entry_response], or raises Problem::Raised.
  def self.call(id, attributes, claims)
    entry = EntryCommand.held!(id, claims)
    entry.project_facts = EntryCommand.project!(attributes.fetch("project_id", entry.project_id), claims)
    entry.caller_role = claims.fetch("role")
    entry.assign_attributes(attributes)
    raise Problem::Raised, EntryCommand.invalid(entry) unless entry.valid?(Entry::UPDATE)

    EntryCommand.saved!(entry, claims)
  end
end
