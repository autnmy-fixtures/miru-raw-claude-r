# frozen_string_literal: true

# Who may update or discard an entry (docs/architecture/timekeeping-soa.md
# §2.1 A3-A5, §6.2): TimesheetEntryPolicy#update? and #destroy? as they
# decide it today, checked again here against the entry row the write holds
# FOR UPDATE, with the caller's role and the company's edit window from the
# token (§2.2, §6.1). The gateway authorized the caller on the entry it read
# just before the call; this check is the one that holds inside the write,
# so an entry billed in between is still refused.
#
# The first refusal that holds wins, in the policy's order. A caller with no
# user (the system actor of §6.1) is refused first: today's policy always has
# a user, and no writer sends an update or discard without one.
#
# W2's bulk move and bulk discard are not refused here but locked (A9,
# lock!): BulkActionController#entry_locked? is A3 and A4 of this policy,
# answered as entry-locked for the whole request. It does not check A5,
# because the caller's policy scope (A6) already chose the entries.
module EntryPolicy
  # The roles the policy treats as privileged in the entry's company.
  PRIVILEGED = %w[owner admin].freeze

  Refusal = Data.define(:reason, :refuses)

  SYSTEM = Refusal.new(reason: "no user caller may change an entry",
    refuses: ->(_entry, claims) { claims.fetch("sub") == "system" })
  BILLED = Refusal.new(reason: "a billed entry cannot be changed (A3)",
    refuses: ->(entry, _claims) { entry.bill_status == "billed" })
  OUTSIDE_WINDOW = Refusal.new(reason: "the entry is older than the company's edit window (A4)",
    refuses: ->(entry, claims) { !privileged?(claims) && entry.work_date < claims.fetch("timesheet_edit_days").days.ago.to_date })
  SOMEONE_ELSES = Refusal.new(reason: "only an owner, an admin or the entry's own user may change it (A5)",
    refuses: ->(entry, claims) { !privileged?(claims) && "user:#{entry.user_id}" != claims.fetch("sub") })

  # TimesheetEntryPolicy#update? and #destroy?, in its order.
  REFUSALS = [SYSTEM, BILLED, OUTSIDE_WINDOW, SOMEONE_ELSES].freeze

  # BulkActionController#entry_locked?, in its order (A9).
  LOCKS = [BILLED, OUTSIDE_WINDOW].freeze

  # Raises forbidden, naming why, unless the caller may change `entry`.
  def self.authorize!(entry, claims)
    refused!(entry, claims, REFUSALS, slug: "forbidden")
  end

  # Raises entry-locked, naming the first entry and why, when any of
  # `entries` is locked against the caller (A9).
  def self.lock!(entries, claims)
    entries.each { |entry| refused!(entry, claims, LOCKS, slug: "entry-locked") }
  end

  def self.privileged?(claims) = PRIVILEGED.include?(claims.fetch("role"))

  def self.refused!(entry, claims, refusals, slug:)
    refusal = refusals.find { |candidate| candidate.refuses.call(entry, claims) }
    return unless refusal

    raise Problem::Raised, Problem.new(slug:, status: 403, detail: "entry #{entry.id}: #{refusal.reason}")
  end
  private_class_method :refused!
end
