# frozen_string_literal: true

require "rails_helper"

# Two calls carrying one Idempotency-Key at once (§9.4): the gateway's retry
# can overtake its own first attempt after a lost response. The second waits
# for the first's transaction and then replays its receipt, so the change is
# made once.
#
# Other connections cannot see an example's own transaction, so this runs
# without one and deletes what it wrote afterwards.
RSpec.describe "EntryWrite across connections" do
  self.use_transactional_tests = false

  def wait_seconds = 5

  def on_own_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |thread| thread.report_on_exception = false }
  end

  def waiting_on_lock?(pid)
    (wait_seconds * 10).times do
      return true if ActiveRecord::Base.connection.select_value(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid = #{Integer(pid)} AND wait_event_type = 'Lock')"
      )

      sleep 0.1
    end
    false
  end

  let(:call) { EntryWrite::Call.new(company_id: 1, generation: 1, key: "key-1", digest: "digest-1") }

  before { Ownership.create!(generation: 1, owner: "timekeeping", state: "open") }

  after do
    [IdempotencyReceipt, EntryAudit, OutboxSnapshot, Entry, Ownership].each(&:delete_all)
  end

  it "makes a second call with the same key wait, then replay the first one's answer" do
    changes = Queue.new
    first_inside = Queue.new
    finish_first = Queue.new
    second_pid = Queue.new

    first = on_own_connection do
      EntryWrite.call(call) do
        changes << :first
        first_inside << true
        finish_first.pop(timeout: wait_seconds)
        [201, { "made_by" => "first" }]
      end
    end
    first_inside.pop(timeout: wait_seconds) or raise "first call never ran"

    second = on_own_connection do |connection|
      second_pid << connection.select_value("SELECT pg_backend_pid()")
      EntryWrite.call(call) do
        changes << :second
        [201, { "made_by" => "second" }]
      end
    end

    expect(waiting_on_lock?(second_pid.pop(timeout: wait_seconds))).to be(true)
    finish_first << true

    expect(first.value).to eq([201, { "made_by" => "first" }])
    expect(second.value).to eq([201, { "made_by" => "first" }])
    expect(Array.new(changes.size) { changes.pop }).to eq([:first])
    expect(IdempotencyReceipt.count).to eq(1)
  end
end
