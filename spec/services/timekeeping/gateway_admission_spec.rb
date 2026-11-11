# frozen_string_literal: true

require "rails_helper"

# The generation fence of docs/architecture/timekeeping-soa.md §10.1, across
# connections: "Raising the generation takes the row exclusively. It
# therefore waits for admitted transactions to finish, and afterwards refuses
# every stale command."
#
# The other connections cannot see the example's own transaction, so these
# examples commit the ownership row from a connection of their own and delete
# it afterwards. The command they run is a bulk discard of no entries: it
# passes the whole fence and writes nothing, so nothing else needs cleaning.
RSpec.describe "Timekeeping gateway admission across connections", type: :model do
  gateway = Timekeeping::Gateway

  let(:command) { gateway::BulkDiscard.new(entries: TimesheetEntry.none) }
  let(:raise_generation) { { generation: 1, state: "closed" } }

  # Every wait is bounded, so a broken fence fails the example instead of
  # leaving a thread parked on a queue with a pooled connection.
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

  # The lock wait starts within milliseconds of the command being sent.
  def wait_until_waiting_on_lock(connection, pid)
    (wait_seconds * 10).times do
      return true if waiting_on_lock?(connection, pid)

      sleep 0.1
    end
    false
  end

  before { run_on_own_connection { Timekeeping::Ownership.create!(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF) } }

  after { run_on_own_connection { Timekeeping::Ownership.delete_all } }

  it "makes a handoff that raises the generation wait for a command already admitted" do
    admitted = Queue.new
    finish = Queue.new
    # Entries whose discard pauses inside the legacy handler, so the command
    # is admitted and still running in the gateway's own transaction.
    pausing_entries = Object.new
    pausing_entries.define_singleton_method(:discard_all) do
      admitted << true
      finish.pop(timeout: 5)
      []
    end
    writer = on_own_connection { gateway.call(gateway::BulkDiscard.new(entries: pausing_entries)) }

    begin
      take(admitted)
      handoff_while_admitted = on_own_connection do |connection|
        connection.transaction do
          connection.execute("SET LOCAL lock_timeout = '300ms'")
          Timekeeping::Ownership.lock.find(Timekeeping::Ownership::SINGLETON_ID).update!(raise_generation)
        end
      end
      expect { handoff_while_admitted.value }.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      finish << true
      writer.join
    end

    run_on_own_connection { Timekeeping::Ownership.find(Timekeeping::Ownership::SINGLETON_ID).update!(raise_generation) }
    expect(run_on_own_connection { Timekeeping::Ownership.current.summary }).to eq("generation 1, owner legacy, state closed")
  end

  it "makes a command that arrives during the handoff wait, then refuses it as ownership moving" do
    handoff_locked = Queue.new
    writer_pid = Queue.new
    handoff = on_own_connection do |connection|
      connection.transaction do
        Timekeeping::Ownership.lock.find(Timekeeping::Ownership::SINGLETON_ID).update!(raise_generation)
        handoff_locked << true
        wait_until_waiting_on_lock(connection, take(writer_pid))
      end
    end
    take(handoff_locked)

    writer = on_own_connection do |connection|
      writer_pid << connection.select_value("SELECT pg_backend_pid()")
      gateway.call(command)
    end

    expect(handoff.value).to be(true), "the command never waited on the handoff's lock"
    expect { writer.value }.to raise_error(gateway::OwnershipMoving)
  end
end
