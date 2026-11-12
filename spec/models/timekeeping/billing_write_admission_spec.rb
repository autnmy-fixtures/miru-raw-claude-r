# frozen_string_literal: true

require "rails_helper"

# The billing-write fence of docs/architecture/timekeeping-soa.md §10.1,
# across connections (§12.4, "Billing writes during a handoff"): "With a
# billing write paused inside its transaction, start a handoff: step 1 waits
# until the write commits or aborts." And a billing write that arrives while
# the handoff holds the row waits, then is refused.
#
# The other connections cannot see the example's own transaction, so the
# ownership row is committed from a connection of its own and deleted
# afterwards. Each billing write creates its records inside a transaction it
# rolls back, so nothing else needs cleaning. The invoice is sent, so its save
# never reaches the entry lock callbacks and the gateway's own fence: what is
# measured is the billing fence alone.
RSpec.describe "Timekeeping billing-write admission across connections", type: :model do
  include TimekeepingConnections

  def close_admission!(lock_timeout: Timekeeping::HandoffFence::DRAIN_TIMEOUT)
    Timekeeping::HandoffFence.call(:close, generation: 0, lock_timeout:)
  end

  # A sent invoice and its payment, saved in a transaction that is rolled
  # back once `pause` returns.
  def billing_write(pause = -> { })
    Invoice.transaction do
      invoice = create(:invoice, status: :sent, amount: 100, amount_due: 100)
      create(:payment, invoice:, amount: 100)
      pause.call
      raise ActiveRecord::Rollback
    end
  end

  before { run_on_own_connection { Timekeeping::Ownership.create!(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF) } }

  after { run_on_own_connection { Timekeeping::Ownership.delete_all } }

  it "makes a handoff that raises the generation wait for a billing write already admitted" do
    admitted = Queue.new
    finish = Queue.new
    writer = on_own_connection do
      billing_write(-> {
        admitted << true
        finish.pop(timeout: wait_seconds)
      })
    end

    begin
      take(admitted)
      handoff_while_admitted = on_own_connection do |connection|
        close_admission!(lock_timeout: 0.3.seconds)
      end
      expect { handoff_while_admitted.value }.to raise_error(ActiveRecord::LockWaitTimeout)
    ensure
      finish << true
      writer.join
    end

    run_on_own_connection { close_admission! }
    expect(run_on_own_connection { Timekeeping::Ownership.current.summary }).to eq("generation 1, owner legacy, state closed")
  end

  it "makes a billing write that arrives during the handoff wait, then refuses it as ownership moving" do
    handoff_locked = Queue.new
    writer_pid = Queue.new
    handoff = on_own_connection do |connection|
      connection.transaction do
        close_admission!
        handoff_locked << true
        wait_until_waiting_on_lock(connection, take(writer_pid))
      end
    end
    take(handoff_locked)

    writer = on_own_connection do |connection|
      writer_pid << connection.select_value("SELECT pg_backend_pid()")
      billing_write
    end

    expect(handoff.value).to be(true), "the billing write never waited on the handoff's lock"
    expect { writer.value }.to raise_error(Timekeeping::Ownership::Moving)
  end
end
