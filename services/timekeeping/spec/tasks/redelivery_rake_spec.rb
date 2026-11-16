# frozen_string_literal: true

require "rails_helper"
require "rake"

# The operator's redelivery (§13 item 6; OutboxRedelivery): it takes the
# entries from ENTRIES, prints each batch and its receipt, and exits 1 when
# it refuses or a receipt is not the one the consumer must answer.
RSpec.describe "timekeeping:redeliver" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:held) { {} }
  let(:server) do
    ProjectionServer.new do |request|
      snapshots = request.body.fetch("snapshots")
      applied = snapshots.group_by { |snapshot| snapshot["entry_id"] }.count do |id, all|
        version = all.map { |snapshot| snapshot["version"] }.max
        next false if held.fetch(id, 0) >= version

        held[id] = version
      end
      [200, { "content-type" => "application/json" }, [JSON.generate("applied" => applied, "ignored" => snapshots.size - applied)]]
    end.start
  end
  let(:entry) { entry!(company_id: 1) }

  around do |example|
    saved = ENV.fetch("ENTRIES", nil)
    config = Rails.configuration.x.timekeeping
    url, key = config.existing_app_url, config.token_key
    config.existing_app_url, config.token_key = server.url, "relay-test-token-key"
    example.run
  ensure
    ENV["ENTRIES"] = saved
    config.existing_app_url, config.token_key = url, key
    server.stop
  end

  before do
    Rake::Task["timekeeping:redeliver"].reenable
    Ownership.current.update!(generation: 1, owner: "timekeeping", state: "open")
    [1, 2].each do |version|
      entry.outbox_snapshots.create!(company_id: 1, version:, request_id: "req-#{version}", snapshot: OutboxSnapshot.of(entry).merge("version" => version))
    end
  end

  def run_task = Rake::Task["timekeeping:redeliver"].invoke

  it "prints each batch and its receipt" do
    ENV["ENTRIES"] = entry.id.to_s

    expect { run_task }.to output(<<~OUT).to_stdout
      redelivery: newest: #{entry.id}@2: applied 1, ignored 0
      redelivery: older: #{entry.id}@1: applied 0, ignored 1
      redelivery: again: #{entry.id}@1 #{entry.id}@2: applied 0, ignored 2
      redelivery: 3 batches of 1 entries' snapshots resent out of order and twice; the consumer applied each entry's newest once and ignored every other
    OUT
  end

  it "exits 1 when the projection already holds the newest" do
    ENV["ENTRIES"] = entry.id.to_s
    held[entry.id] = 2

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/redelivery failed: the consumer answered .* to the newest batch/).to_stderr
  end

  it "exits 1 without ENTRIES, or with something that is not an id" do
    [nil, "", "12 abc"].each do |value|
      Rake::Task["timekeeping:redeliver"].reenable
      ENV["ENTRIES"] = value

      expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
        .and output(/ENTRIES names/).to_stderr
    end
    expect(server.received).to be_empty
  end

  it "exits 1 when Timekeeping does not own the entries" do
    ENV["ENTRIES"] = entry.id.to_s
    Ownership.current.update!(owner: "monolith")

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/redelivery failed: a redelivery runs while Timekeeping owns the entries/).to_stderr
  end
end
