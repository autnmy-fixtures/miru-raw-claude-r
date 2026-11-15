# frozen_string_literal: true

# What every change of a prepared application's entry writes beside the entry
# row, in the change's own transaction (docs/architecture/timekeeping-soa.md
# §3.4, §5.4, §10.1): its audit row, and the outbox row that
# Timekeeping::LocalRelay delivers to the projection. It is what Timekeeping's
# EntryChange writes for its own entries, with the same arguments, so an
# entry changed by either owner leaves the same rows behind and a checkpoint
# carries them unchanged (§10.5 step 4).
#
# timesheet_entries is not written here: under the `monolith` owner it stays a
# projection, written only by the projection consumer (§3.3: nothing writes
# through from the request path). An entry change that skips this recorder is
# invisible to every report and to a re-cutover, so every `monolith` writer
# records through here: so far the single-entry and bulk writes of
# Timekeeping::Gateway::Local.
module Timekeeping::LocalEntryChange
  # Records `entry` as it was just saved by `action`, made by the caller the
  # claims name (Timekeeping::UserToken's claims, §6.1). `audited_changes` is
  # what `audited` records today: on create every audited column, on update
  # each changed one as [before, after]. A change to no audited column writes
  # no audit row, as `audited` writes none today; its snapshot is still
  # written. The snapshot reads the entry's reservations as they stand in
  # this transaction, never a cached read from before the change, so its
  # derived `locked` is the one the change left (§7.1).
  def self.record!(entry, action:, audited_changes:, claims:)
    if audited_changes.any?
      entry.audits.create!(
        company_id: entry.company_id, action:, audited_changes:, version: entry.version,
        actor: claims.fetch("sub"), agent_id: claims.dig("actor", "agent_id"),
        writer: claims.fetch("writer"), request_id: claims.fetch("request_id")
      )
    end
    entry.reservations.reset
    entry.outbox_snapshots.create!(
      company_id: entry.company_id, version: entry.version,
      snapshot: Timekeeping::OutboxSnapshot.of(entry), request_id: claims.fetch("request_id")
    )
  end
end
