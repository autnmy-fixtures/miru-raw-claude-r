# frozen_string_literal: true

require "rails_helper"

# The relay (§5.4): every outbox snapshot reaches the projection endpoint as
# the entry snapshot contract defines the delivery, is marked delivered only
# once the consumer confirms it, and is never skipped. This is also the
# provider side of that contract's tests (§12.3).
RSpec.describe OutboxRelay do
  let(:key) { "relay-test-token-key" }
  let(:server) { ProjectionServer.new.start }
  let(:entry) { entry!(company_id: 1) }

  after { server.stop }

  def relay(url: server.url, batch_size: OutboxRelay::BATCH_SIZE)
    described_class.new(url:, token_key: key, batch_size:)
  end

  def snapshot!(entry, version: entry.version, request_id: "req-#{version}", **attributes)
    entry.outbox_snapshots.create!(
      company_id: entry.company_id, version:, request_id:,
      snapshot: OutboxSnapshot.of(entry).merge("version" => version), **attributes
    )
  end

  def delivered?(row) = row.reload.delivered_at.present?

  it "delivers every undelivered snapshot, in outbox order, as the contract defines the call" do
    rows = [snapshot!(entry, version: 1), snapshot!(entry, version: 2), snapshot!(entry!(company_id: 2), version: 1)]

    result = relay.run

    expect(result).to eq(OutboxRelay::Result.new(delivered: 3, undelivered: 0))
    expect(rows).to all(satisfy { |row| delivered?(row) })

    (request,) = server.received
    operation = contract_document(:entry_snapshot).dig("x-operations", "deliver_snapshots")
    expect([request.method, request.path]).to eq([operation.fetch("method"), operation.fetch("path")])
    expect(request.headers.keys).to include(*contract_document(:entry_snapshot).dig("x-headers", "every"))
    expect(contract_errors(:entry_snapshot, "#/$defs/snapshot_batch", request.body)).to be_empty
    expect(request.body.fetch("snapshots")).to eq(rows.map(&:snapshot))
  end

  it "authenticates with the relay's service token, signed with the shared key, 60 s TTL" do
    snapshot!(entry)
    relay.run

    token = server.received.first.headers.fetch("Authorization").delete_prefix("Bearer ")
    claims, = JWT.decode(token, key, true, algorithm: "HS256", aud: "projection", verify_aud: true)
    expect(contract_errors(:entry_snapshot, "#/$defs/service_token_claims", claims)).to be_empty
    expect(claims.fetch("exp") - claims.fetch("iat")).to eq(60)
  end

  it "carries a request id of its own, and logs the request ids of the changes it carries" do
    snapshot!(entry, request_id: "req-change-1")
    allow(Rails.logger).to receive(:info).and_call_original

    relay.run

    request_id = server.received.first.headers.fetch("X-Request-Id")
    expect(request_id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    expect(Rails.logger).to have_received(:info).with(a_string_including(request_id, "req-change-1"))
  end

  it "delivers the stored float duration exactly (§5.1)" do
    durations = [90.7, 0.1, 479.99999]
    durations.each { |duration| snapshot!(entry!(company_id: 1, duration:)) }

    relay.run

    expect(server.received.first.body.fetch("snapshots").map { |snapshot| snapshot.dig("data", "duration") }).to eq(durations)
  end

  it "sends batches of at most the batch size until the outbox is drained" do
    rows = Array.new(5) { |index| snapshot!(entry, version: index + 1) }

    expect(relay(batch_size: 2).run).to eq(OutboxRelay::Result.new(delivered: 5, undelivered: 0))
    expect(server.received.map { |request| request.body.fetch("snapshots").size }).to eq([2, 2, 1])
    expect(rows).to all(satisfy { |row| delivered?(row) })
  end

  it "never sends a delivered snapshot again" do
    first = snapshot!(entry, version: 1)
    relay.run
    second = snapshot!(entry, version: 2)
    server.received

    expect(relay.run).to eq(OutboxRelay::Result.new(delivered: 1, undelivered: 0))
    expect(server.received.map { |request| request.body.fetch("snapshots").map { |snapshot| snapshot.fetch("version") } }).to eq([[2]])
    expect([first, second]).to all(satisfy { |row| delivered?(row) })
  end

  it "sends nothing when nothing is undelivered" do
    expect(relay.run).to eq(OutboxRelay::Result.new(delivered: 0, undelivered: 0))
    expect(server.received).to be_empty
  end

  it "still delivers a snapshot that becomes visible below a position already delivered" do
    later = snapshot!(entry, version: 2)
    relay.run
    earlier = snapshot!(entry, version: 1, id: later.id - 1)

    relay.run

    expect(delivered?(earlier)).to be(true)
  end

  context "when the consumer does not confirm the batch" do
    def refusing(status, body)
      ProjectionServer.new { [status, { "content-type" => "application/problem+json" }, [JSON.generate(body)]] }.start
    end

    let(:problem) { { "type" => "https://contracts.timekeeping.internal/problems/forbidden", "title" => "Forbidden", "status" => 403, "retryable" => false } }

    before do
      allow(Rails.error).to receive(:report)
      allow(Rails.logger).to receive(:error).and_call_original
    end

    it "leaves a refused batch undelivered and reports it, and the next run sends it again" do
      row = snapshot!(entry)
      refused = refusing(403, problem)

      expect(relay(url: refused.url).run).to eq(OutboxRelay::Result.new(delivered: 0, undelivered: 1))
      expect(delivered?(row)).to be(false)
      expect(Rails.error).to have_received(:report).with(an_instance_of(OutboxRelay::Undelivered).and(having_attributes(message: a_string_including("403"))), hash_including(handled: true))
      expect(Rails.logger).to have_received(:error).with(a_string_including("the projection answered 403"))

      expect(relay.run).to eq(OutboxRelay::Result.new(delivered: 1, undelivered: 0))
      expect(delivered?(row)).to be(true)
    ensure
      refused&.stop
    end

    it "takes only the contract's receipt as confirmation" do
      row = snapshot!(entry)
      odd = ProjectionServer.new { [200, { "content-type" => "application/json" }, ['{"ok":true}']] }.start

      expect(relay(url: odd.url).run).to eq(OutboxRelay::Result.new(delivered: 0, undelivered: 1))
      expect(delivered?(row)).to be(false)
    ensure
      odd&.stop
    end

    it "keeps the batches already confirmed and stops at the first one that is not" do
      rows = Array.new(3) { |index| snapshot!(entry, version: index + 1) }
      calls = 0
      flaky = ProjectionServer.new { |request|
        calls += 1
        next [503, {}, [""]] if calls == 2

        ProjectionServer::RECEIPT.call(request)
      }.start

      expect(relay(url: flaky.url, batch_size: 1).run).to eq(OutboxRelay::Result.new(delivered: 1, undelivered: 1))
      expect(rows.map { |row| delivered?(row) }).to eq([true, false, false])
    ensure
      flaky&.stop
    end

    it "leaves the batch undelivered when the consumer cannot be reached" do
      row = snapshot!(entry)
      unreachable = "http://127.0.0.1:#{server.url.split(':').last}"
      server.stop

      expect(relay(url: unreachable).run).to eq(OutboxRelay::Result.new(delivered: 0, undelivered: 1))
      expect(delivered?(row)).to be(false)
      expect(Rails.error).to have_received(:report).with(an_instance_of(OutboxRelay::Undelivered), hash_including(handled: true))
    end
  end

  it "refuses to run without the existing application's URL or the shared token key (§11.2)" do
    expect { described_class.new(url: nil, token_key: key) }.to raise_error(OutboxRelay::NotConfigured, /EXISTING_APP_URL/)
    expect { described_class.new(url: server.url, token_key: "") }.to raise_error(OutboxRelay::NotConfigured, /TIMEKEEPING_TOKEN_KEY/)
  end
end
