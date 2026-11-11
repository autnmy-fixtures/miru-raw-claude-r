# frozen_string_literal: true

# The projection consumer of docs/architecture/timekeeping-soa.md §3.2 and
# §5.4: once Timekeeping owns entries, the one writer of timesheet_entries.
#
# It upserts each entry snapshot by (entry_id, version) and ignores anything
# not newer, so a duplicated or reordered delivery changes nothing. Values are
# copied as they arrive: duration stays the float it was (§8), and no model
# callback, validation or audit runs, because the row is a copy of what
# Timekeeping already decided.
#
# The batch takes snapshots already validated against the entry snapshot
# contract. It is refused whole, and nothing is applied, when any snapshot's
# company is not the company of its project, or of the row it would
# overwrite (§6.3).
class Timekeeping::ProjectionConsumer < ApplicationService
  Applied = Data.define(:applied, :ignored)
  Refused = Data.define(:entry_ids)

  Snapshot = Data.define(:entry_id, :version, :company_id, :data) do
    def self.from(payload)
      new(**payload.slice("entry_id", "version", "company_id", "data").symbolize_keys)
    end

    def project_id = data.fetch("project_id")
    def row = data.merge("id" => entry_id, "version" => version)
  end

  def initialize(snapshots)
    @snapshots = snapshots.map { |payload| Snapshot.from(payload) }
  end

  def process
    latest = @snapshots.group_by(&:entry_id).values.map { |versions| versions.max_by(&:version) }
    foreign = foreign_entry_ids(latest)
    return Refused.new(entry_ids: foreign) if foreign.any?

    applied = upsert(latest)
    Applied.new(applied:, ignored: @snapshots.size - applied)
  end

  private

    def foreign_entry_ids(snapshots)
      by_project = Project.joins(:client).where(id: snapshots.map(&:project_id)).pluck(:id, "clients.company_id").to_h
      by_row = TimesheetEntry.joins(project: :client).where(id: snapshots.map(&:entry_id)).pluck(:id, "clients.company_id").to_h

      snapshots.reject { |snapshot|
        [by_project[snapshot.project_id], by_row.fetch(snapshot.entry_id, snapshot.company_id)].all?(snapshot.company_id)
      }.map(&:entry_id).sort
    end

    # One statement: insert new rows, overwrite a stored row only from a higher
    # version. RETURNING lists exactly the rows it wrote.
    def upsert(snapshots)
      TimesheetEntry.upsert_all(
        snapshots.map(&:row),
        unique_by: :id,
        record_timestamps: false,
        returning: [:id],
        on_duplicate: Arel.sql("#{assignments} WHERE timesheet_entries.version < EXCLUDED.version")
      ).length
    end

    def assignments
      connection = TimesheetEntry.connection
      (TimesheetEntry.column_names - ["id"]).map { |column|
        quoted = connection.quote_column_name(column)
        "#{quoted} = EXCLUDED.#{quoted}"
      }.join(", ")
    end
end
