# frozen_string_literal: true

# The prepared application's entry store (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): the authoritative entries the `monolith` owner holds, which
# Timekeeping::LocalReservations takes as its `entries`, and the
# candidates invoice selection reads under that owner.
#
# `lock(ids)` takes the entry rows SELECT ... FOR UPDATE in id order (§9.4),
# so reservation changes serialize with entry edits and with each other, as
# Timekeeping's ReservationProtocol locks its entries. It answers
# { id => TimekeepingReservations::Entry } for the ids that exist, discarded
# ones included: existence and company are what the rule decides on (L8).
#
# `prepared(ids)` answers the prepare facts of each id that exists, in the
# order asked (Timekeeping::Entry#to_prepared): project, user, duration, work
# date and the version the change left, as Timekeeping's prepare answers
# them. LocalReservations reads them after it wrote the change, in the same
# transaction, from the rows `lock` already holds.
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
#
# `candidates` is invoice candidate selection under the `monolith` owner
# (§3.3 rule 1): a read that decides money reads the owner's own table, never
# the projection, which may lag. It takes the arguments
# Timekeeping::EntryClient#candidates takes and answers the same
# EntryClient::Candidate values, selected as Timekeeping's CandidateList
# selects them: the kept, unbilled entries of the company (§6.3) that the
# shared rule finds selectable (a retained reservation does not count, L3,
# L4), narrowed by each filter, by search rank when there is a search term,
# then by id. The note search is TimesheetEntry's own pg_search scope, which
# Timekeeping writes out as SQL.
class Timekeeping::LocalEntries
  WRITER = Timekeeping::ReservationClient::WRITER
  UNBILLED = "unbilled"

  def lock(ids)
    Timekeeping::Entry.where(id: ids).order(:id).lock.pluck(:id, :company_id)
      .to_h { |id, company_id| [id, TimekeepingReservations::Entry.new(id:, company_id:)] }
  end

  def prepared(ids)
    Timekeeping::Entry.where(id: ids).index_by(&:id).values_at(*ids).compact.map(&:to_prepared)
  end

  # `user_ids` nil is no restriction; an empty list selects nothing, as an
  # empty IN list does. `work_dates` is an inclusive Range of Dates, or nil.
  # `client_id` narrows nothing more: the client's kept projects arrive
  # resolved as `project_ids`, as the entry API takes them. It is taken so
  # either owner's candidates answer the same call.
  # :reek:UnusedParameters
  def candidates(company:, client_id:, project_ids:, user_ids: nil, exclude_ids: [], work_dates: nil, search_term: nil) # rubocop:disable Lint/UnusedMethodArgument
    entries = Timekeeping::Entry.of_company(company.id).kept.where(bill_status: UNBILLED, project_id: project_ids)
    entries = entries.where(user_id: user_ids) unless user_ids.nil?
    entries = entries.where.not(id: exclude_ids) if exclude_ids.present?
    entries = entries.where(work_date: work_dates) if work_dates
    entries = entries.pg_search(search_term) if search_term.present?
    entries.includes(:reservations).order(:id).filter_map do |entry|
      candidate(entry) if TimekeepingReservations.selectable?(entry.id, entry.reservations.map(&:to_value))
    end
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

    def candidate(entry)
      Timekeeping::EntryClient::Candidate.new(**Timekeeping::EntryClient::Candidate.members.index_with { |field| entry.public_send(field) })
    end

    def claims(operation)
      Timekeeping::UserToken.system_claims(
        company: Company.find(operation.company_id), writer: WRITER,
        request_id: Rails.event.context[:request_id] || SecureRandom.uuid
      )
    end
end
