# frozen_string_literal: true

# Entry discard (docs/architecture/timekeeping-soa.md §5.2): W1 web and
# mobile, W3 CLI and MCP. A3-A5 against the entry as it stands, held FOR
# UPDATE (EntryPolicy), and then the entry is discarded.
#
# Today's discard! writes discarded_at with update_attribute, which runs no
# validation, so none of the update rules run here either. The edit lock
# among them: an employee may discard their own locked entry today (it is
# TimesheetEntryPolicy that decides, and it does not read `locked`). The
# entry's reservations are left as they are, as today's discard leaves
# `locked`.
module EntryDiscard
  # Answers [200, entry_response], or raises Problem::Raised.
  def self.call(id, claims)
    entry = EntryCommand.held!(id, claims)
    entry.discarded_at = Time.current
    EntryCommand.saved!(entry, claims)
  end
end
