# frozen_string_literal: true

# The projection's version column (docs/architecture/timekeeping-soa.md §3.2).
# The projection consumer applies an entry snapshot only when its version is
# higher than the stored one. Contract versions start at 1, so 0 means no
# snapshot has been applied to the row yet: every row written before
# Timekeeping owns entries.
class AddVersionToTimesheetEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :timesheet_entries, :version, :bigint, null: false, default: 0
  end
end
