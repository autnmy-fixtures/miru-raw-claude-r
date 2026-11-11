# frozen_string_literal: true

require "rails_helper"

# The seed and demo-data builders (W8) of docs/architecture/timekeeping-soa.md
# §10.1 are not gateway writers. Each reads the ownership record before its
# first write and, once a handoff has begun, refuses and writes nothing.
RSpec.describe "Timekeeping: seed and demo-data builders after a handoff has begun", type: :model do
  include TimekeepingOwnershipStates

  builders = {
    "db/seeds.rb" => -> { load Rails.root.join("db/seeds.rb").to_s, true },
    "db/seeds/timesheet_data.rb" => -> { load Rails.root.join("db/seeds/timesheet_data.rb").to_s, true },
    "Analytics::DemoSeeder" => -> { Analytics::DemoSeeder.new(company: Company.first).process }
  }

  # Every row of every table, so "writes nothing" covers whatever a builder
  # would have touched first.
  def row_counts
    connection = ActiveRecord::Base.connection
    connection.tables.sort.index_with do |table|
      connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}")
    end
  end

  before { create(:company) }

  builders.each do |builder, run|
    TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.each do |state, attributes|
      it "#{builder} refuses and writes nothing once #{state}" do
        set_timekeeping_ownership!(attributes)
        before = row_counts

        expect { instance_exec(&run) }
          .to raise_error(Timekeeping::Ownership::HandoffBegun, /\A#{Regexp.escape(builder)} refused/)
        expect(row_counts).to eq(before)
      end
    end
  end
end
