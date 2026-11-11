# frozen_string_literal: true

require "rails_helper"

# The consumer-side fake of the relay holds to the entry snapshot contract
# (docs/architecture/timekeeping-soa.md §5.4, §12.3). The projection consumer
# does not exist yet, so a minimal consumer here applies by (entry_id, version)
# as the contract states, which shows what a batch the fake sends looks like.
RSpec.describe TimekeepingContracts::FakeRelay do
  subject(:relay) { described_class.new }

  let(:consumer) do
    Class.new do
      attr_reader :rows, :requests

      def initialize
        @rows = {}
        @requests = []
      end

      def call(env)
        request = Rack::Request.new(env)
        @requests << request
        snapshots = JSON.parse(request.body.read).fetch("snapshots")
        applied = snapshots.count do |snapshot|
          newer = snapshot["version"] > @rows.dig(snapshot["entry_id"], "version").to_i
          @rows[snapshot["entry_id"]] = snapshot if newer
          newer
        end
        [200, { "content-type" => "application/json" }, [JSON.generate("applied" => applied, "ignored" => snapshots.size - applied)]]
      end
    end.new
  end

  let(:columns) { { company_id: 42, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02" } }

  it "builds a snapshot with every column, and refuses one that misses a column without a default" do
    snapshot = relay.snapshot(entry_id: 101, version: 1, **columns)

    expect(snapshot["data"].keys).to match_array(TimesheetEntry.column_names - ["id"])
    expect { relay.snapshot(entry_id: 101, version: 1, **columns.except(:work_date)) }.to raise_error(TimekeepingContracts::Violation, /work_date/)
  end

  it "delivers to the projection path with the relay's service token and a request id" do
    relay.deliver(consumer, [relay.snapshot(entry_id: 101, version: 1, **columns)])
    request = consumer.requests.first
    claims = TimekeepingContracts.decode(request.get_header("HTTP_AUTHORIZATION").delete_prefix("Bearer "), key: TimekeepingContracts::TEST_TOKEN_KEY, audience: "projection")

    expect(request.path_info).to eq("/internal/v1/projection/entry_snapshots")
    expect(claims["sub"]).to eq("service:timekeeping-relay")
    expect(request.get_header("HTTP_X_REQUEST_ID")).to be_present
  end

  it "sends duplicates and reordered versions, which an upsert by version absorbs" do
    older = relay.snapshot(entry_id: 101, version: 1, **columns)
    newer = relay.snapshot(entry_id: 101, version: 2, **columns, locked: true)

    expect(relay.deliver(consumer, [older, newer], order: :reversed)).to eq("applied" => 1, "ignored" => 1)
    expect(relay.deliver(consumer, [older, newer], order: :duplicated)).to eq("applied" => 0, "ignored" => 4)
    expect(consumer.rows[101]).to eq(newer)
  end

  it "keeps a float duration exact on the wire" do
    relay.deliver(consumer, [relay.snapshot(entry_id: 101, version: 1, **columns, duration: 479.99999)])

    expect(consumer.rows.dig(101, "data", "duration")).to eq(479.99999)
  end

  it "raises on a refused delivery, as the relay retries it" do
    refusing = ->(_env) { [503, {}, ["down"]] }

    expect { relay.deliver(refusing, [relay.snapshot(entry_id: 101, version: 1, **columns)]) }.to raise_error(TimekeepingContracts::Violation, /503/)
  end
end
