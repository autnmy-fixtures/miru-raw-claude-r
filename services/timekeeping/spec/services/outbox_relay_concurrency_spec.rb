# frozen_string_literal: true

require "rails_helper"

# Two relays at once (§5.4): the dispatcher enqueues a run every second, so a
# slow delivery can overlap the next. The second run skips the rows the first
# holds instead of waiting on them or sending them too.
#
# Other connections cannot see an example's own transaction, so this runs
# without one and deletes what it wrote afterwards.
RSpec.describe "OutboxRelay across connections" do
  self.use_transactional_tests = false

  def wait_seconds = 5

  let(:held) { Queue.new }
  let(:release) { Queue.new }
  let(:server) do
    ProjectionServer.new { |request|
      if request.body.fetch("snapshots").any? { |snapshot| snapshot.fetch("version") == 1 }
        held << true
        release.pop(timeout: wait_seconds)
      end
      ProjectionServer::RECEIPT.call(request)
    }.start
  end

  after do
    server.stop
    [OutboxSnapshot, Entry].each(&:delete_all)
  end

  def relay = OutboxRelay.new(url: server.url, token_key: "relay-test-token-key", batch_size: 1)

  def snapshot!(entry, version:)
    entry.outbox_snapshots.create!(company_id: entry.company_id, version:, request_id: "req-#{version}", snapshot: OutboxSnapshot.of(entry).merge("version" => version))
  end

  it "delivers the rows a running delivery does not hold, and leaves that delivery's rows to it" do
    entry = entry!(company_id: 1)
    first, second = snapshot!(entry, version: 1), snapshot!(entry, version: 2)

    slow = Thread.new { ActiveRecord::Base.connection_pool.with_connection { relay.run } }
    held.pop(timeout: wait_seconds) or raise "the first delivery never reached the consumer"

    overlapping = ActiveRecord::Base.connection_pool.with_connection { relay.run }
    expect(overlapping).to eq(OutboxRelay::Result.new(delivered: 1, undelivered: 0))
    expect(second.reload.delivered_at).to be_present
    expect(first.reload.delivered_at).to be_nil

    release << true
    expect(slow.value).to eq(OutboxRelay::Result.new(delivered: 1, undelivered: 0))
    expect(first.reload.delivered_at).to be_present
  end
end
