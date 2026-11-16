# frozen_string_literal: true

require "rails_helper"
require "rake"

# The read of both copies of the ownership record (docs/architecture/
# timekeeping-soa.md §10.1) that the acceptance run (bin/timekeeping-demo
# acceptance) checks before each step: its last line is the owner,
# generation and state the two copies agree on.
RSpec.describe "timekeeping:ownership", type: :model do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:handoff_client) { instance_double(Timekeeping::HandoffClient) }
  let(:outbox) { Timekeeping::HandoffClient::Outbox.new(**Timekeeping::HandoffClient::Outbox.members.index_with { 0 }) }

  before do
    Rake::Task["timekeeping:ownership"].reenable
    allow(Timekeeping::HandoffClient).to receive(:new).and_return(handoff_client)
  end

  def timekeeping_copy(generation:, owner:, state:)
    allow(handoff_client).to receive(:status)
      .and_return(Timekeeping::HandoffClient::Status.new(copy: Timekeeping::HandoffClient::Copy.new(generation:, owner:, state:), outbox:))
  end

  def run_task = Rake::Task["timekeeping:ownership"].invoke

  it "prints both copies, then the one they agree on, in the initial legacy state" do
    timekeeping_copy(generation: 0, owner: "legacy", state: "open")

    expect { run_task }.to output(<<~OUT).to_stdout
      existing application: generation 0, owner legacy, state open
      Timekeeping: generation 0, owner legacy, state open
      legacy 0 open
    OUT
  end

  it "prints the owner both copies name after a handoff" do
    Timekeeping::Ownership.create!(generation: 2, owner: "monolith", state: "open")
    timekeeping_copy(generation: 2, owner: "monolith", state: "open")

    expect { run_task }.to output(/\Aexisting application: generation 2, owner monolith, state open\n.*\nmonolith 2 open\n\z/).to_stdout
  end

  it "exits non-zero, naming no owner, when the copies differ" do
    Timekeeping::Ownership.create!(generation: 1, owner: "timekeeping", state: "frozen")
    timekeeping_copy(generation: 1, owner: "timekeeping", state: "open")

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/Timekeeping: generation 1, owner timekeeping, state open\n\z/).to_stdout
      .and output(/the two copies of the ownership record differ/).to_stderr
  end

  it "exits non-zero when Timekeeping's copy cannot be read" do
    allow(handoff_client).to receive(:status).and_raise(Timekeeping::HandoffClient::Unavailable, "connection refused")

    expect { run_task }.to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      .and output(/Timekeeping's copy of the ownership record could not be read: connection refused/).to_stderr
  end
end
