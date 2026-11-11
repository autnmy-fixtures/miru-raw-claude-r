# frozen_string_literal: true

require "rails_helper"

# The one ownership record of docs/architecture/timekeeping-soa.md §10.1 and
# the one test its gates share: has a handoff begun?
RSpec.describe Timekeeping::Ownership, type: :model do
  include TimekeepingOwnershipStates

  describe ".current" do
    it "is the initial legacy state, unsaved, when no handoff has ever written the record" do
      ownership = described_class.current

      aggregate_failures do
        expect(ownership).to be_new_record
        expect(ownership.attributes.symbolize_keys.slice(:generation, :owner, :state))
          .to eq(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF)
      end
    end

    it "is the stored record once one exists" do
      stored = set_timekeeping_ownership!(generation: 1, owner: "timekeeping", state: "open")

      expect(described_class.current).to eq(stored)
    end
  end

  describe ".handoff_begun?" do
    it "is false when no record exists" do
      expect(described_class.handoff_begun?).to be(false)
    end

    it "is false for a record still in the initial legacy state" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF)

      expect(described_class.handoff_begun?).to be(false)
    end

    # §10.1 names both halves of the test. The handoff tool raises the
    # generation as it closes admission, so these records come from no
    # procedure step, but the record admits them and they must still refuse.
    %w[closed frozen].each do |state|
      it "is true for a #{state} record whose generation was never raised" do
        set_timekeeping_ownership!(generation: 0, owner: "legacy", state:)

        expect(described_class.handoff_begun?).to be(true)
      end
    end

    TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.each do |name, attributes|
      it "is true once #{name}" do
        set_timekeeping_ownership!(attributes)

        expect(described_class.handoff_begun?).to be(true)
      end
    end
  end

  describe ".ensure_initial!" do
    it "returns before the first handoff" do
      expect(described_class.ensure_initial!("a builder")).to be_nil
    end

    it "raises with the builder and the ownership it found once a handoff has begun" do
      set_timekeeping_ownership!(generation: 2, owner: "monolith", state: "open")

      expect { described_class.ensure_initial!("a builder") }.to raise_error(
        described_class::HandoffBegun,
        /\Aa builder refused: .*generation 2, owner monolith, state open/
      )
    end
  end

  describe "the database" do
    it "holds one record at most" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::BEFORE_FIRST_HANDOFF)

      expect { described_class.create!(id: 2) }
        .to raise_error(ActiveRecord::StatementInvalid, /timekeeping_ownerships_singleton/)
    end

    it "refuses a negative generation" do
      expect { described_class.create!(generation: -1) }
        .to raise_error(ActiveRecord::StatementInvalid, /timekeeping_ownerships_generation_non_negative/)
    end

    # Written as SQL because the enums refuse these values before the database
    # would see them.
    def insert_ownership(column, value)
      described_class.connection.execute(<<~SQL.squish)
        INSERT INTO timekeeping_ownerships (id, #{column}, created_at, updated_at)
        VALUES (#{described_class::SINGLETON_ID}, '#{value}', now(), now())
      SQL
    end

    it "refuses an owner outside the design's three" do
      expect { insert_ownership(:owner, "billing") }
        .to raise_error(ActiveRecord::StatementInvalid, /timekeeping_ownerships_owner/)
    end

    it "refuses a state outside open, closed and frozen" do
      expect { insert_ownership(:state, "paused") }
        .to raise_error(ActiveRecord::StatementInvalid, /timekeeping_ownerships_state/)
    end
  end
end
