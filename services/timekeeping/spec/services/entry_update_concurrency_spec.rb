# frozen_string_literal: true

require "rails_helper"

# An update checks A3-A5 against the entry row it holds FOR UPDATE (§6.2,
# §9.4), not against the entry the gateway read before the call. So a change
# to the same entry that commits while the update waits, here an import
# marking it billed, is the state the update is decided on: it is refused
# (A3) instead of overwriting the billed entry.
#
# Other connections cannot see an example's own transaction, so this runs
# without one and deletes what it wrote afterwards.
RSpec.describe "EntryUpdate across connections" do
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
    user_token_claims(company_id: 1, role: "employee", project: { "id" => 11, "company_id" => 1, "kept" => true, "billable" => true })
  end

  before { Ownership.create!(generation: 1, owner: "timekeeping", state: "open") }

  after do
    [IdempotencyReceipt, EntryAudit, OutboxSnapshot, Entry, Ownership].each(&:delete_all)
  end

  it "waits for a change that holds the entry, then decides on what it committed" do
    entry = entry!(company_id: 1, work_date: Date.current)
    held = Queue.new
    release = Queue.new
    update_pid = Queue.new

    billing = on_own_connection do
      Entry.transaction do
        Entry.lock.find(entry.id).update!(bill_status: "billed")
        held << true
        release.pop(timeout: wait_seconds)
      end
    end
    held.pop(timeout: wait_seconds) or raise "the billing change never held the entry"

    updating = on_own_connection do |connection|
      update_pid << connection.select_value("SELECT pg_backend_pid()")
      call = EntryWrite::Call.new(company_id: 1, generation: 1, key: "key-1", digest: "digest-1")
      EntryWrite.call(call) { EntryUpdate.call(entry.id, { "project_id" => 11, "note" => "Overwritten" }, claims) }
    rescue Problem::Raised => raised
      raised.problem
    end

    expect(waiting_on_lock?(update_pid.pop(timeout: wait_seconds))).to be(true)
    release << true
    billing.join

    expect(updating.value).to have_attributes(slug: "forbidden", detail: include("(A3)"))
    expect(entry.reload).to have_attributes(bill_status: "billed", note: "", version: 1)
  end
end
