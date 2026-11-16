# frozen_string_literal: true

# The single-writer guard of docs/architecture/timekeeping-soa.md §12.2, at
# runtime: the "single-writer guard violations (CI and the local demo)" row
# of the observability table (§11.3). In CI the guard is a spec
# (spec/requests/timekeeping/single_writer_guard_spec.rb); this is the same
# test in a running process.
#
# Once entries have left the legacy owner, timesheet_entries is a read model
# with one writer, the projection consumer (§3.2, §3.3). Every SQL statement
# this application sends is watched (`sql.active_record`), and one that
# inserts, updates or deletes timesheet_entries is a violation when it did
# not run inside Timekeeping::ProjectionConsumer and this application's copy
# of the ownership record is anything but `legacy` and `open`:
#
# - `legacy` and `open` (before the first handoff, or after an aborted one)
#   is the one state in which today's model code still writes the table,
#   through the gateway's legacy owner and the seed builders;
# - `legacy` and `closed` or `frozen` is the first handoff: the gateway
#   refuses every write (Ownership.admit!), so only the consumer writes;
# - `timekeeping` and `monolith` own entries in their own tables, and the
#   table is the consumer's alone.
#
# The ownership record is read only for a statement that writes the table.
# The subscriber runs on the thread that sent the statement, so the read is
# on the writer's own connection, inside its transaction: a gateway write
# holds the row FOR SHARE, so a handoff cannot move it under the read. A
# statement that failed changed nothing and is not read at all.
#
# Each violation is reported as it happens, through Timekeeping::Signals
# (Rails.error and the log at error level), naming the statement, the gateway
# command it ran under if any, the application frame that sent it, and the
# ownership record. The write itself is never refused or changed here. A
# failure of the watch is logged and swallowed, and its one statement, the
# read of the ownership row, is sent only once that table exists, so the
# watch does not break the writer it watches.
#
# It sees what runs in this application's processes (web, workers, rake and
# console), not SQL sent to the database from outside them, such as psql.
module Timekeeping::SingleWriterWatch
  WRITE_SQL = %r{\A\s*(?:/\*.*?\*/\s*)*(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+"timesheet_entries"}im
  PROJECTION_KEY = :timekeeping_single_writer_projection
  SQL_SHOWN = 300
  WATCH_FRAMES = %w[app/services/timekeeping/single_writer_watch.rb config/initializers/timekeeping.rb].freeze

  def self.write_sql?(sql) = sql.is_a?(String) && sql.match?(WRITE_SQL)

  # Runs the projection consumer's writes: the one writer the watch allows
  # once entries have left the legacy owner.
  def self.projection
    outer = projection?
    ActiveSupport::IsolatedExecutionState[PROJECTION_KEY] = true
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[PROJECTION_KEY] = outer
  end

  def self.projection? = ActiveSupport::IsolatedExecutionState[PROJECTION_KEY] || false

  def self.enabled? = Rails.configuration.x.timekeeping.single_writer_watch != false

  # The `sql.active_record` subscriber (config/initializers/timekeeping.rb).
  def self.call(_name, _started, _finished, _id, payload)
    sql = payload[:sql]
    return unless write_sql?(sql)
    return if projection? || payload[:exception] || !enabled?

    check(sql)
  rescue StandardError => error
    Rails.logger.warn("Timekeeping single-writer watch could not check a write: #{error.class}: #{error.message}")
  end

  def self.check(sql)
    return unless Timekeeping::Ownership.table_exists?

    ownership = Timekeeping::Ownership.current
    return if ownership.owner_legacy? && ownership.state_open?

    Timekeeping::Signals.report(violation(sql.squish.truncate(SQL_SHOWN), ownership))
  end
  private_class_method :check

  def self.violation(sql, ownership)
    command = Timekeeping::Gateway.current_command&.class&.name
    source = sending_frame
    writer = command ? "gateway command #{command.demodulize}" : "a path outside the gateway"
    Timekeeping::Signals::Alert.new(
      :single_writer,
      "timesheet_entries was written by #{writer}#{" at #{source}" if source}, not by the projection consumer, " \
        "under #{ownership.summary}: #{sql}",
      sql:, command:, source:, ownership: ownership.summary
    )
  end
  private_class_method :violation

  # The first frame of this repository's code that sent the statement, past
  # the watch and its subscription, relative to the root: app, lib, db (the
  # seeds), script or spec alike. Nil for code from outside it, such as a
  # console line.
  def self.sending_frame
    root = "#{Rails.root}/"
    caller_locations.each do |location|
      path = location.absolute_path || location.path
      next unless path&.start_with?(root)

      relative = path.delete_prefix(root)
      next if relative.start_with?("vendor/") || WATCH_FRAMES.include?(relative)

      return "#{relative}:#{location.lineno}"
    end
    nil
  end
  private_class_method :sending_frame
end
