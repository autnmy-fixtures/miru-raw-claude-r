# frozen_string_literal: true

# The single-writer guard of docs/architecture/timekeeping-soa.md §12.2:
# records every SQL statement that writes timesheet_entries while a block
# runs, with the gateway command (if any) it ran under. A write with no
# command came from a path that bypasses Timekeeping::Gateway.
module TimekeepingSingleWriterGuard
  Write = Data.define(:sql, :command)

  WRITE_SQL = /\A\s*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"timesheet_entries"/i

  def timesheet_entry_writes(&writer)
    writes = []
    record = lambda do |*, payload|
      writes << Write.new(sql: payload[:sql], command: Timekeeping::Gateway.current_command) if payload[:sql].match?(WRITE_SQL)
    end

    ActiveSupport::Notifications.subscribed(record, "sql.active_record", &writer)
    writes
  end
end
