# frozen_string_literal: true

require "rails_helper"

# The generation fence of docs/architecture/timekeeping-soa.md §10.1 on
# Timekeeping's copy, across connections: "Raising the generation takes the
# row exclusively. It therefore waits for admitted transactions to finish,
# and afterwards refuses every stale command."
#
# Other connections cannot see an example's own transaction, so these
# examples run without one, commit the record from their own connections,
# and delete it afterwards.
RSpec.describe "Timekeeping admission across connections" do
  self.use_transactional_tests = false

  def wait_seconds = 5

  def on_own_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |thread| thread.report_on_exception = false }
  end

  def take(queue) = queue.pop(timeout: wait_seconds) || raise("timed out waiting for another connection")

  def waiting_on_lock?(connection, pid)
    (wait_seconds * 10).times do
      return true if connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = #{Integer(pid)} AND wait_event_type = 'Lock')"
      )

      sleep 0.1
    end
    false
  end

  # A mutating call: admitted inside its own write transaction, as every
  # endpoint admits.
  def call_admitted(generation, &while_admitted)
    Ownership.transaction do
      Ownership.admit!(generation)
      while_admitted&.call
    end
  end

  before { Ownership.create!(generation: 1, owner: "timekeeping", state: "open") }

  after { Ownership.delete_all }

  it "makes close wait for a call already admitted" do
    admitted = Queue.new
    finish = Queue.new
    call = on_own_connection do
      call_admitted(1) do
        admitted << true
        finish.pop(timeout: wait_seconds)
      end
    end

    begin
      take(admitted)
      close_while_admitted = on_own_connection { HandoffFence.call(:close, generation: 1, lock_timeout: 0.3.seconds) }
      expect { close_while_admitted.value }.to raise_error(ActiveRecord::LockWaitTimeout)
      expect(Ownership.current.summary).to eq("generation 1, owner timekeeping, state open")
    ensure
      finish << true
      call.join
    end

    on_own_connection { HandoffFence.call(:close, generation: 1) }.join
    expect(Ownership.current.summary).to eq("generation 2, owner timekeeping, state closed")
  end

  it "makes a call that arrives during close wait, then refuses it as stale" do
    locked = Queue.new
    caller_pid = Queue.new
    close = on_own_connection do |connection|
      connection.transaction do
        HandoffFence.call(:close, generation: 1)
        locked << true
        waiting_on_lock?(connection, take(caller_pid))
      end
    end
    take(locked)

    call = on_own_connection do |connection|
      caller_pid << connection.select_value("SELECT pg_backend_pid()")
      call_admitted(1)
    end

    expect(close.value).to be(true), "the call never waited on the close's lock"
    expect { call.value }.to raise_error(Ownership::Refused) { |refused| expect(refused.problem.slug).to eq("stale-generation") }
  end

  # §10.5 step 2: a commit or abort admitted under the old generation by the
  # settle step's exception is drained by freeze as close drains a call, so
  # nothing settle applies can commit after the checkpoint's freeze.
  it "makes freeze wait for a settle call admitted under the old generation, then refuses the next as stale" do
    HandoffFence.call(:close, generation: 1)
    admitted = Queue.new
    finish = Queue.new
    call = on_own_connection do
      Ownership.transaction do
        Ownership.admit!(1, settle: true)
        admitted << true
        finish.pop(timeout: wait_seconds)
      end
    end

    begin
      take(admitted)
      freeze_while_admitted = on_own_connection { HandoffFence.call(:freeze, generation: 2, lock_timeout: 0.3.seconds) }
      expect { freeze_while_admitted.value }.to raise_error(ActiveRecord::LockWaitTimeout)
      expect(Ownership.current.summary).to eq("generation 2, owner timekeeping, state closed")
    ensure
      finish << true
      call.join
    end

    on_own_connection { HandoffFence.call(:freeze, generation: 2) }.join
    late = on_own_connection { Ownership.transaction { Ownership.admit!(1, settle: true) } }
    expect { late.value }.to raise_error(Ownership::Refused) { |refused| expect(refused.problem.slug).to eq("stale-generation") }
  end
end
