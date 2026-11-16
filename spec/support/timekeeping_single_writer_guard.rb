# frozen_string_literal: true

# The single-writer guard of docs/architecture/timekeeping-soa.md §12.2:
# records every SQL statement that writes timesheet_entries while a block
# runs, with the gateway command (if any) it ran under. A write with no
# command came from a path that bypasses Timekeeping::Gateway. What counts as
# a write is the runtime watch's test (Timekeeping::SingleWriterWatch), so the
# spec and the running application agree.
module TimekeepingSingleWriterGuard
  Write = Data.define(:sql, :command)

  def timesheet_entry_writes(&writer)
    writes = []
    record = lambda do |*, payload|
      writes << Write.new(sql: payload[:sql], command: Timekeeping::Gateway.current_command) if Timekeeping::SingleWriterWatch.write_sql?(payload[:sql])
    end

    ActiveSupport::Notifications.subscribed(record, "sql.active_record", &writer)
    writes
  end
end
