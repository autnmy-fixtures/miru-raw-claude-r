# frozen_string_literal: true

require "rails_helper"

# Timekeeping::Gateway (docs/architecture/timekeeping-soa.md §3.1) in legacy
# mode (§10.2 step 2). The single-writer guard spec runs every writer through
# it; this spec pins the gateway's own rules: one handler per command, the
# owner taken from the ownership record read under the generation fence
# (§10.1), no write while admission is closed, and no local write under an
# owner, or for a command, not built yet. gateway_admission_spec.rb proves the
# fence's locking across connections, and gateway_remote_spec.rb the
# timekeeping owner's forwarding.
RSpec.describe Timekeeping::Gateway, type: :model do
  include TimekeepingCharacterization::Helpers
  include TimekeepingSingleWriterGuard

  let(:tenant) { build_tenant }
  let!(:entry) { unbilled_entry(tenant) }

  def discard_command
    described_class::DiscardEntry.new(entry:, writer: "web")
  end

  # A command the timekeeping owner does not forward yet.
  def unforwarded_command
    described_class::ImportEntry.new(company: tenant.company, attributes: {}, billed: false)
  end

  it "has exactly one legacy handler for every command it defines" do
    commands = described_class.constants.map { |name| described_class.const_get(name) }
      .select { |constant| constant.is_a?(Class) && constant < Data }

    expect(described_class::Legacy::HANDLERS.keys).to match_array(commands)
  end

  it "forwards only the single-entry and bulk commands under the timekeeping owner" do
    expect(described_class::Remote::REQUESTS.keys).to contain_exactly(
      described_class::CreateEntry, described_class::UpdateEntry, described_class::DiscardEntry,
      described_class::BulkMove, described_class::BulkDiscard
    )
  end

  context "with no ownership record (the initial legacy state)" do
    it "runs the legacy handler under the command and returns its result" do
      result = nil
      writes = timesheet_entry_writes { result = described_class.call(discard_command) }

      expect(result).to be(true)
      expect(entry.reload).to be_discarded
      expect(writes.map(&:command)).to all(eq(discard_command))
    end
  end

  it "runs the legacy handler when the record names the legacy owner" do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF)

    described_class.call(discard_command)

    expect(entry.reload).to be_discarded
  end

  it "writes the initial ownership row it locks when none exists, without changing what it means" do
    expect { described_class.call(discard_command) }.to change(Timekeeping::Ownership, :count).from(0).to(1)

    expect(Timekeeping::Ownership.current.attributes.symbolize_keys.slice(:generation, :owner, :state))
      .to eq(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF)
    expect(Timekeeping::Ownership).not_to be_handoff_begun
  end

  # The fence (§10.1): admission closed refuses every command, whoever the
  # owner is; with admission open, the legacy owner runs every command and
  # the timekeeping owner refuses the commands it does not forward yet.
  TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.each do |state, attributes|
    refusal, pattern = if attributes[:state] != "open"
      [Timekeeping::Ownership::Moving, /being moved between services/]
    elsif attributes[:owner] != "legacy"
      [described_class::OwnerUnavailable, /owner #{attributes[:owner]} .* ImportEntry refused/]
    end

    if refusal
      it "refuses with #{refusal.name.demodulize} and writes nothing once #{state}" do
        set_timekeeping_ownership!(attributes)

        writes = timesheet_entry_writes do
          expect { described_class.call(unforwarded_command) }.to raise_error(refusal, pattern)
        end

        expect(writes).to eq([])
        expect(entry.reload).not_to be_discarded
      end
    else
      it "runs the legacy handler once #{state}, because admission reopened under the same owner" do
        set_timekeeping_ownership!(attributes)

        described_class.call(discard_command)

        expect(entry.reload).to be_discarded
      end
    end
  end

  describe ".current_command" do
    it "is nil outside a command" do
      expect(described_class.current_command).to be_nil
    end

    it "is reset when the handler raises" do
      entry.discard!

      expect { described_class.call(discard_command) }.to raise_error(Discard::RecordNotDiscarded)
      expect(described_class.current_command).to be_nil
    end
  end
end
