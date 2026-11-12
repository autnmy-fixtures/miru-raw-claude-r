# frozen_string_literal: true

require "rails_helper"

# A bulk move checks A9's lock against the entry rows it holds FOR UPDATE
# (§6.2, §9.4), not against the entries the gateway read before the call. So
# a change to one of them that commits while the move waits, here an import
# marking it billed, is the state the move is decided on: the whole request
# is refused as entry-locked, and neither entry moves.
#
# Other connections cannot see an example's own transaction, so this runs
# without one and deletes what it wrote afterwards.
RSpec.describe "EntryBulk across connections" do
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

  let(:claims) do
    user_token_claims(company_id: 1, role: "employee", writer: "bulk", project: { "id" => 13, "company_id" => 1, "kept" => true, "billable" => true })
  end

  before { Ownership.create!(generation: 1, owner: "timekeeping", state: "open") }

  after do
    [IdempotencyReceipt, EntryAudit, OutboxSnapshot, Entry, Ownership].each(&:delete_all)
  end

  it "waits for a change that holds one of its entries, then decides on what it committed" do
    free = entry!(company_id: 1, work_date: Date.current)
    billed_meanwhile = entry!(company_id: 1, work_date: Date.current)
    held = Queue.new
    release = Queue.new
    move_pid = Queue.new

    billing = on_own_connection do
      Entry.transaction do
        Entry.lock.find(billed_meanwhile.id).update!(bill_status: "billed")
        held << true
        release.pop(timeout: wait_seconds)
      end
    end
    held.pop(timeout: wait_seconds) or raise "the billing change never held the entry"

    moving = on_own_connection do |connection|
      move_pid << connection.select_value("SELECT pg_backend_pid()")
      call = EntryWrite::Call.new(company_id: 1, generation: 1, key: "key-1", digest: "digest-1")
      EntryWrite.call(call) { EntryBulk.move([free.id, billed_meanwhile.id], 13, claims) }
    rescue Problem::Raised => raised
      raised.problem
    end

    expect(waiting_on_lock?(move_pid.pop(timeout: wait_seconds))).to be(true)
    release << true
    billing.join

    expect(moving.value).to have_attributes(slug: "entry-locked", detail: include("entry #{billed_meanwhile.id}", "(A3)"))
    expect([free.reload, billed_meanwhile.reload].map { |entry| [entry.project_id, entry.version] }).to eq([[11, 1], [11, 1]])
    expect(OutboxSnapshot.count).to eq(0)
  end
end
