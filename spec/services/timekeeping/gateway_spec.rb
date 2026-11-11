# frozen_string_literal: true

require "rails_helper"

# Timekeeping::Gateway (docs/architecture/timekeeping-soa.md §3.1) in legacy
# mode (§10.2 step 2). The single-writer guard spec runs every writer through
# it; this spec pins the gateway's own rules: one handler per command, the
# owner taken from the ownership record, and no local write under an owner
# that is not built yet.
RSpec.describe Timekeeping::Gateway, type: :model do
  include TimekeepingCharacterization::Helpers
  include TimekeepingSingleWriterGuard

  let(:tenant) { build_tenant }
  let!(:entry) { unbilled_entry(tenant) }

  def discard_command
    described_class::DiscardEntry.new(entry:)
  end

  it "has exactly one legacy handler for every command it defines" do
    commands = described_class.constants.map { |name| described_class.const_get(name) }
      .select { |constant| constant.is_a?(Class) && constant < Data }

    expect(described_class::Legacy::HANDLERS.keys).to match_array(commands)
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

  TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.reject { |_, attributes| attributes[:owner] == "legacy" }
    .each do |state, attributes|
      it "refuses and writes nothing once #{state}" do
        set_timekeeping_ownership!(attributes)

        writes = timesheet_entry_writes do
          expect { described_class.call(discard_command) }
            .to raise_error(described_class::OwnerUnavailable, /owner #{attributes[:owner]} .* DiscardEntry refused/)
        end

        expect(writes).to eq([])
        expect(entry.reload).not_to be_discarded
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
