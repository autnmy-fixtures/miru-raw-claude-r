# frozen_string_literal: true

# docs/architecture/timekeeping-soa.md §10.2 step 3: drop the two keys from
# billing to entries before cutover. Once Timekeeping owns entries,
# timesheet_entries is a projection that can lag, and these keys would refuse
# a line item for an entry that is not projected yet. The indexes stay. The
# key from timesheet_entries to users stays too (§10.1).
class DropBillingForeignKeysToTimesheetEntries < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :invoice_line_item_time_entries, :timesheet_entries
    remove_foreign_key :invoice_line_items, :timesheet_entries
  end
end
