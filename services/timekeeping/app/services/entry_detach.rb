# frozen_string_literal: true

# W6's agent detach (docs/architecture/timekeeping-soa.md §3.1, §5.2, §6.2):
# what `dependent: :nullify` does to the agent's entries today, as one
# mutating call in one transaction (EntryWrite).
#
# Today's nullify is `update_all(agent_id: nil)` over every entry that names
# the agent (K8), so here:
#
# 1. every entry of the token's company that names the agent is held FOR
#    UPDATE, in id order, discarded ones included, as update_all reaches
#    them too; another company's entry is never among them, the one check
#    Timekeeping makes for W6 (§6.2, §6.3);
# 2. no rule runs and no role is read, as update_all runs no validation;
# 3. each entry's agent_id is nulled as its next version, with its audit row
#    and its outbox snapshot (EntryChange), and updated_at kept, as
#    update_all keeps it.
#
# An agent no entry names detaches nothing and answers no ids, so a repeat
# under a new key is harmless.
module EntryDetach
  # Answers [200, detach_agent_response].
  def self.call(agent_id, claims)
    named = Entry.of_company(claims.fetch("company_id")).where(agent_id:).order(:id).lock.includes(:reservations).to_a
    named.each do |entry|
      entry.agent_id = nil
      EntryCommand.saved!(entry, claims, touch: false)
    end

    [200, { "detached_ids" => named.map(&:id) }]
  end
end
