# frozen_string_literal: true

# W2's bulk move and bulk discard (docs/architecture/timekeeping-soa.md §5.2,
# §3.4, §6.2), each one mutating call in one transaction (EntryWrite).
#
# The gateway sends the ids the caller's policy scope selected (A6) and has
# already checked A9 on the entries it read. Here, in the write:
#
# 1. the named kept entries of the token's company are held FOR UPDATE, in
#    id order, so two bulk calls over the same entries cannot deadlock; an id
#    of another company, a discarded entry or a missing one is not among
#    them, as it is not in the caller's selection today;
# 2. A9's lock is checked on every one of them (EntryPolicy.lock!): one
#    billed entry, or one outside the edit window for anyone but owner and
#    admin, refuses the whole request as entry-locked, with nothing written;
# 3. each entry is changed on its own, as today's relation update and
#    discard_all change each record on its own.
#
# A move runs TimesheetEntry's update rules on each entry, as relation
# `update` does today, with the target project's facts from the token. An
# entry the rules reject is skipped, not refused, and the call still answers
# 200 (A9's silent skip, K12): an employee's locked entry, or an unbilled
# entry moved to a non-billable project. A discard runs no rule, as today's
# discard runs none.
module EntryBulk
  # Answers [200, bulk_move_response].
  def self.move(ids, project_id, claims)
    project = EntryCommand.project!(project_id, claims)
    moved, skipped = held!(ids, claims).partition { |entry| moved?(entry, project, claims) }

    [200, {
      "moved_ids" => moved.map(&:id), "skipped_ids" => skipped.map(&:id),
      "entries" => (moved + skipped).sort_by(&:id).map(&:to_contract)
    }]
  end

  # Answers [200, bulk_discard_response].
  def self.discard(ids, claims)
    discarded = held!(ids, claims).each do |entry|
      entry.discarded_at = Time.current
      EntryCommand.saved!(entry, claims)
    end

    [200, { "discarded_ids" => discarded.map(&:id) }]
  end

  def self.held!(ids, claims)
    entries = Entry.of_company(claims.fetch("company_id")).kept.where(id: ids).order(:id).lock.includes(:reservations).to_a
    entries.tap { EntryPolicy.lock!(entries, claims) }
  end
  private_class_method :held!

  # Saves `entry` in `project` when the update rules accept it; otherwise
  # leaves it as it stands and answers false.
  def self.moved?(entry, project, claims)
    entry.project_facts = project
    entry.caller_role = claims.fetch("role")
    entry.project_id = project.fetch("id")
    unless entry.valid?(Entry::UPDATE)
      entry.restore_attributes
      return false
    end

    EntryCommand.saved!(entry, claims)
    true
  end
  private_class_method :moved?
end
