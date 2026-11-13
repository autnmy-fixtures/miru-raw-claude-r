# frozen_string_literal: true

require "rails_helper"

# Two invoices preparing the same entry at once (F1, §9.4). Each prepare
# holds the entry FOR UPDATE before it reads the entry's reservations, so the
# second waits for the first and then sees its provisional reservation: one
# is prepared, the other refused as on_other_invoice. Neither reaches the
# unique index, which is the backstop, not the lock.
#
# Other connections cannot see an example's own transaction, so this runs
# without one and deletes what it wrote afterwards.
RSpec.describe "ReservationProtocol across connections" do
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

  let(:company_id) { 1 }
  let(:claims) do
    { "sub" => "system", "company_id" => company_id, "actor" => { "type" => "system", "agent_id" => nil },
      "writer" => "invoice", "request_id" => "req-1" }
  end

  def prepare_on_own_connection(invoice_id, entry, pids)
    on_own_connection do |connection|
      pids << connection.select_value("SELECT pg_backend_pid()")
      call = ReservationProtocol::Call.new(claims:, invoice_id:, operation_id: SecureRandom.uuid, generation: 1)
      ReservationProtocol.prepare(call, {
        "company_id" => company_id, "kind" => "save", "invoice_state" => "draft", "entry_ids" => [entry.id], "resolves" => nil
      })
    end
  end

  before { Ownership.create!(generation: 1, owner: "timekeeping", state: "open") }

  after do
    [OutboxSnapshot, EntryAudit, Reservation, ReservationOperation, Entry, Ownership].each(&:delete_all)
  end

  it "prepares the entry for one invoice and refuses it for the other" do
    entry = Entry.create!(company_id:, project_id: 11, user_id: 7, duration: 60.0, work_date: Date.new(2026, 11, 2), bill_status: "unbilled")
    pids = Queue.new
    prepares = []

    # This connection holds the entry row, so both prepares queue up behind it.
    Entry.transaction do
      Entry.lock.find(entry.id)
      prepares = [601, 602].map { |invoice_id| prepare_on_own_connection(invoice_id, entry, pids) }
      expect(Array.new(2) { waiting_on_lock?(pids.pop(timeout: wait_seconds)) }).to eq([true, true])
    end

    answers = prepares.map(&:value)
    expect(answers.map(&:first)).to contain_exactly(200, 409)
    refused = answers.find { |status, _| status == 409 }.last
    expect(refused).to include("refused" => [{ "entry_id" => entry.id, "reason" => "on_other_invoice" }])
    expect(Reservation.where(entry_id: entry.id).count).to eq(1)
    expect(entry.reload.version).to eq(2)
  ensure
    prepares.each { |thread| thread.join(wait_seconds) }
  end
end
