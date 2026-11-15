# frozen_string_literal: true

# The prepared application's entry store (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): the authoritative entries the `monolith` owner holds, which
# Timekeeping::LocalReservations takes as its `entries`. It is inactive: no
# owner routes to it until the `monolith` owner is built.
#
# `lock(ids)` takes the entry rows SELECT ... FOR UPDATE in id order (§9.4),
# so reservation changes serialize with entry edits and with each other, as
# Timekeeping's ReservationProtocol locks its entries. It answers
# { id => TimekeepingReservations::Entry } for the ids that exist, discarded
# ones included: existence and company are what the rule decides on (L8).
#
# `reservations_changed!` records each entry whose reservations a change
# just wrote, as ReservationProtocol.record_changes! records Timekeeping's:
# the entry is saved as its next version, with the outbox snapshot that
# carries its derived `locked` to the projection (§5.4), through
# Timekeeping::LocalEntryChange. `locked` is not an audited column, so no
# audit row is written. updated_at moves only when `locked` does, as today's
# `update!(locked:)` touches it only then. The caller is the system actor of
# the operation's company with the `invoice` writer, as the reservation
# client's token names it (§6.1). Nothing writes timesheet_entries here;
# the local relay projects the snapshots (§3.3).
class Timekeeping::LocalEntries
  WRITER = Timekeeping::ReservationClient::WRITER

  def lock(ids)
    Timekeeping::Entry.where(id: ids).order(:id).lock.pluck(:id, :company_id)
      .to_h { |id, company_id| [id, TimekeepingReservations::Entry.new(id:, company_id:)] }
  end

  # `was_locked` is { id => locked before the change } for every entry whose
  # reservations changed. LocalReservations calls it after `lock` took those
  # rows, in the same transaction, so they are already held.
  def reservations_changed!(was_locked, operation:)
    claims = claims(operation)
    Timekeeping::Entry.where(id: was_locked.keys).order(:id).includes(:reservations).each do |entry|
      entry.version += 1
      entry.save!(touch: entry.locked? != was_locked.fetch(entry.id))
      Timekeeping::LocalEntryChange.record!(entry, action: "update", audited_changes: {}, claims:)
    end
  end

  private

    def claims(operation)
      Timekeeping::UserToken.system_claims(
        company: Company.find(operation.company_id), writer: WRITER,
        request_id: Rails.event.context[:request_id] || SecureRandom.uuid
      )
    end
end
