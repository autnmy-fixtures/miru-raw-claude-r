# frozen_string_literal: true

# Helpers for the Timekeeping fence specs that run writers and a handoff on
# connections of their own (docs/architecture/timekeeping-soa.md §10.1).
# Every wait is bounded, so a broken fence fails the example instead of
# leaving a thread parked on a queue with a pooled connection.
module TimekeepingConnections
  def wait_seconds = 5

  def on_own_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |thread| thread.report_on_exception = false }
  end

  def run_on_own_connection(&)
    on_own_connection(&).value
  end

  def take(queue)
    queue.pop(timeout: wait_seconds) || raise("timed out waiting for another connection")
  end

  def waiting_on_lock?(connection, pid)
    connection.select_value(
      "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = #{Integer(pid)} AND wait_event_type = 'Lock')"
    )
  end

  # The lock wait starts within milliseconds of the write being sent.
  def wait_until_waiting_on_lock(connection, pid)
    (wait_seconds * 10).times do
      return true if waiting_on_lock?(connection, pid)

      sleep 0.1
    end
    false
  end
end
