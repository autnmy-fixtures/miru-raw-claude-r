# frozen_string_literal: true

# What every entry change writes beside the entry row, in the change's own
# transaction (docs/architecture/timekeeping-soa.md §3.4): its audit row and
# the outbox row the relay delivers to the projection (§5.4). An entry change
# that skips this is invisible to every report and to rollback, so every
# writer records through here.
module EntryChange
  # Records `entry` as it was just saved by `action`, made by the caller the
  # claims name (§6.1). `audited_changes` is what `audited` records today: on
  # create every audited column, on update each changed one as [before,
  # after]. A change to no audited column writes no audit row, as `audited`
  # writes none today; its snapshot is still written.
  def self.record!(entry, action:, audited_changes:, claims:)
    if audited_changes.any?
      entry.audits.create!(
        company_id: entry.company_id, action:, audited_changes:, version: entry.version,
        actor: claims.fetch("sub"), agent_id: claims.dig("actor", "agent_id"),
        writer: claims.fetch("writer"), request_id: claims.fetch("request_id")
      )
    end
    entry.outbox_snapshots.create!(
      company_id: entry.company_id, version: entry.version,
      snapshot: OutboxSnapshot.of(entry), request_id: claims.fetch("request_id")
    )
  end
end
