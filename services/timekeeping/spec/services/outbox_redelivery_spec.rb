# frozen_string_literal: true

require "rails_helper"

# The duplicate and reordered delivery of §13 item 6, sent on purpose
# (OutboxRedelivery): named entries' outbox snapshots go to the projection
# endpoint through the relay's own call, newest first, then each older one
# alone, then all again, and each receipt must be the one a consumer that
# upserts by version answers. The stand-in consumer here keeps the version it
# holds per entry, as the existing application's does.
RSpec.describe OutboxRedelivery do
  let(:key) { "relay-test-token-key" }
  let(:held) { {} }
  # Upsert by (entry_id, version): within a batch the newest per entry; a
  # stored entry is overwritten only from a higher version.
  let(:versioned) do
    lambda do |request|
      snapshots = request.body.fetch("snapshots")
      latest = snapshots.group_by { |snapshot| snapshot["entry_id"] }.values.map { |all| all.max_by { |snapshot| snapshot["version"] } }
      applied = latest.count do |snapshot|
        id, version = snapshot.values_at("entry_id", "version")
        next false if held.fetch(id, 0) >= version

        held[id] = version
      end
      [200, { "content-type" => "application/json" }, [JSON.generate("applied" => applied, "ignored" => snapshots.size - applied)]]
    end
  end
  let(:server) { ProjectionServer.new(&versioned).start }
  let(:relay) { OutboxRelay.new(url: server.url, token_key: key) }
  let(:x) { entry!(company_id: 1) }
  let(:y) { entry!(company_id: 2) }

  before { Ownership.current.update!(generation: 1, owner: "timekeeping", state: "open") }

  after { server.stop }

  def snapshot!(entry, version, delivered: true)
    entry.outbox_snapshots.create!(
      company_id: entry.company_id, version:, request_id: "req-#{entry.id}-#{version}",
      snapshot: OutboxSnapshot.of(entry).merge("version" => version), delivered_at: (Time.current if delivered)
    )
  end

  # X at versions 1-3 and Y at 1-2, interleaved as writes would leave them;
  # the projection has delivered only each entry's first.
  let!(:rows) do
    [snapshot!(x, 1), snapshot!(y, 1), snapshot!(x, 2, delivered: false), snapshot!(y, 2, delivered: false), snapshot!(x, 3, delivered: false)]
  end

  def redelivery(ids = [x.id, y.id], relay: self.relay) = described_class.new(entry_ids: ids, relay:)

  def sent_versions = server.received.map { |request| request.body.fetch("snapshots").map { |snapshot| [snapshot["entry_id"], snapshot["version"]] } }

  context "when the projection holds each entry only at its first version" do
    before { held.merge!(x.id => 1, y.id => 1) }

    it "sends the newest of each first, then each older one alone, newest first, then all of them in outbox order" do
      sent = redelivery.call

      expect(sent_versions).to eq([
        [[x.id, 3], [y.id, 2]],
        [[x.id, 2]], [[x.id, 1]], [[y.id, 1]],
        [[x.id, 1], [y.id, 1], [x.id, 2], [y.id, 2], [x.id, 3]]
      ])
      expect(sent.map(&:step)).to eq(%i[newest older older older again])
      expect(sent.map { |batch| batch.receipt.values_at("applied", "ignored") }).to eq([[2, 0], [0, 1], [0, 1], [0, 1], [0, 5]])
      expect(held).to eq(x.id => 3, y.id => 2)
    end

    it "sends each snapshot as the outbox holds it, through the relay's own call" do
      redelivery.call

      requests = server.received
      operation = contract_document(:entry_snapshot).dig("x-operations", "deliver_snapshots")
      expect(requests.map(&:path).uniq).to eq([operation.fetch("path")])
      expect(requests).to all(satisfy { |request| contract_errors(:entry_snapshot, "#/$defs/snapshot_batch", request.body).empty? })
      expect(requests.last.body.fetch("snapshots")).to eq(rows.map(&:snapshot))
      token = requests.first.headers.fetch("Authorization").delete_prefix("Bearer ")
      expect(JWT.decode(token, key, true, algorithm: "HS256", aud: "projection", verify_aud: true).first).to include("sub" => "service:timekeeping-relay")
    end

    it "marks nothing in the outbox, so the relay still delivers what it had not" do
      redelivery.call

      expect(rows.map { |row| row.reload.delivered_at.present? }).to eq([true, true, false, false, false])
      expect(OutboxRelay.new(url: server.url, token_key: key).run).to eq(OutboxRelay::Result.new(delivered: 3, undelivered: 0))
    end

    it "yields each batch once its receipt checks out" do
      yielded = []
      redelivery.call { |batch| yielded << batch.summary }

      expect(yielded).to eq(["#{x.id}@3 #{y.id}@2", "#{x.id}@2", "#{x.id}@1", "#{y.id}@1", "#{x.id}@1 #{y.id}@1 #{x.id}@2 #{y.id}@2 #{x.id}@3"])
    end
  end

  it "fails on the newest batch when the projection already holds an entry at its latest version" do
    held.merge!(x.id => 3, y.id => 1)

    expect { redelivery.call }.to raise_error(
      described_class::Unexpected,
      /answered \{"applied" => 1, "ignored" => 1\} to the newest batch .*not \{"applied" => 2, "ignored" => 0\}: .*relay was not stopped/
    )
    expect(server.received.size).to eq(1)
  end

  context "when the consumer applies whatever it is sent" do
    let(:server) do
      ProjectionServer.new do |request|
        [200, { "content-type" => "application/json" }, [JSON.generate("applied" => request.body.fetch("snapshots").size, "ignored" => 0)]]
      end.start
    end

    it "fails on the first older snapshot it applies, and sends nothing after it" do
      expect { redelivery.call }.to raise_error(described_class::Unexpected, /to the older batch \(#{x.id}@2\).*applied a snapshot that is not newer/)
      expect(server.received.size).to eq(2)
    end
  end

  it "raises the relay's Undelivered when the consumer refuses a batch" do
    refusing = ProjectionServer.new { [503, { "content-type" => "application/problem+json" }, ["{}"]] }.start

    expect { redelivery(relay: OutboxRelay.new(url: refusing.url, token_key: key)).call }.to raise_error(OutboxRelay::Undelivered, /answered 503/)
  ensure
    refusing&.stop
  end

  describe "refusals, before anything is sent" do
    it "refuses unless Timekeeping owns the entries with admission open" do
      [{ owner: "legacy", state: "open" }, { owner: "monolith", state: "open" }, { owner: "timekeeping", state: "frozen" }].each do |ownership|
        Ownership.current.update!(**ownership)

        expect { redelivery.call }.to raise_error(described_class::Refused, /runs while Timekeeping owns the entries with admission open; this copy says .*#{ownership[:owner]}/)
      end
      expect(server.received).to be_empty
    end

    it "refuses an entry with no snapshot, or only one" do
      lone = entry!(company_id: 1)
      snapshot!(lone, 1)

      expect { redelivery([x.id, 999_999]).call }.to raise_error(described_class::Refused, /holds no snapshot of entry 999999/)
      expect { redelivery([x.id, lone.id]).call }.to raise_error(described_class::Refused, /entry #{lone.id} has 1 snapshot .*needs two/)
      expect { redelivery([]).call }.to raise_error(described_class::Refused, /name at least one entry/)
      expect(server.received).to be_empty
    end
  end
end
