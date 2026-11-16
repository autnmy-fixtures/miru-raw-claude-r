# frozen_string_literal: true

require "rails_helper"

# The single-writer guard of docs/architecture/timekeeping-soa.md §12.2 at
# runtime, the "single-writer guard violations (CI and the local demo)" row
# of §11.3: once entries have left the legacy owner, a write to
# timesheet_entries by anything but the projection consumer is reported as it
# happens, through the subscriber config/initializers/timekeeping.rb installs.
RSpec.describe Timekeeping::SingleWriterWatch do
  include_context "with two Timekeeping tenants"

  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let!(:entry) { unbilled_entry(tenant_a) }

  let(:reported) { [] }

  before do
    allow(Rails.error).to receive(:report).and_wrap_original do |report, error, **options|
      reported << error
      report.call(error, **options)
    end
    allow(Rails.logger).to receive(:error).and_call_original
  end

  def single_writer_alerts
    reported.select { |error| error.is_a?(Timekeeping::Signals::Alert) && error.signal == :single_writer }
  end

  def bypass_write!
    entry.update_column(:note, "bypass")
  end

  def projection_snapshot(version:)
    relay.snapshot(
      entry_id: entry.id, version:, company_id: tenant_a.company.id, project_id: tenant_a.project.id,
      user_id: tenant_a.employee.id, duration: 90.7, work_date: "2026-11-02"
    )
  end

  describe "while the legacy owner holds entries with admission open" do
    it "reports nothing before the first handoff" do
      bypass_write!

      expect(single_writer_alerts).to be_empty
    end

    it "reports nothing after an aborted first handoff, when the legacy owner writes again" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted"))

      bypass_write!

      expect(single_writer_alerts).to be_empty
    end
  end

  TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.except("first handoff aborted").each do |label, attributes|
    describe "#{label} (#{attributes.values_at(:generation, :owner, :state).join(', ')})" do
      before { set_timekeeping_ownership!(attributes) }

      it "reports a write outside the projection consumer, naming the statement, the frame and the record" do
        bypass_write!

        alerts = single_writer_alerts
        expect(alerts.size).to eq(1)
        alert = alerts.first
        expect(alert.message).to include("a path outside the gateway", "not by the projection consumer", "UPDATE \"timesheet_entries\"")
        expect(alert.details).to include(
          command: nil, ownership: Timekeeping::Ownership.current.summary, sql: a_string_starting_with("UPDATE \"timesheet_entries\"")
        )
        expect(alert.details[:source]).to include("spec/services/timekeeping/single_writer_watch_spec.rb")
        expect(Rails.logger).to have_received(:error).with(alert.message)
        expect(entry.reload.note).to eq("bypass")
      end

      it "lets the projection consumer write and reports nothing" do
        outcome = Timekeeping::ProjectionConsumer.process([projection_snapshot(version: entry.version + 1)])

        expect(outcome).to eq(Timekeeping::ProjectionConsumer::Applied.new(applied: 1, ignored: 0))
        expect(single_writer_alerts).to be_empty
      end
    end
  end

  describe "under the timekeeping owner" do
    before { set_timekeeping_ownership!(generation: 1, owner: "timekeeping", state: "open") }

    it "reports an insert, an update and a delete, whatever sends them" do
      other = unbilled_entry(tenant_b)
      TimesheetEntry.where(id: entry.id).update_all(note: "relation")
      TimesheetEntry.connection.execute("DELETE FROM \"timesheet_entries\" WHERE id = #{Integer(other.id)}")

      expect(single_writer_alerts.map { |alert| alert.details[:sql][/\A\w+/] }).to eq(%w[INSERT UPDATE DELETE])
    end

    it "names the gateway command a write ran under" do
      command = Timekeeping::Gateway::DetachAgent.allocate
      allow(Timekeeping::Gateway).to receive(:current_command).and_return(command)

      bypass_write!

      expect(single_writer_alerts.first).to have_attributes(message: a_string_including("gateway command DetachAgent"))
      expect(single_writer_alerts.first.details).to include(command: "Timekeeping::Gateway::DetachAgent")
    end

    it "reports nothing for a read, or for a write to another table" do
      TimesheetEntry.where(id: entry.id).to_a
      tenant_a.project.update_column(:name, "Renamed")

      expect(single_writer_alerts).to be_empty
    end

    it "sees a statement behind a leading SQL comment" do
      TimesheetEntry.connection.execute("/* tagged */ UPDATE \"timesheet_entries\" SET note = 'c' WHERE id = #{Integer(entry.id)}")

      expect(single_writer_alerts.size).to eq(1)
    end

    it "reports nothing for a statement that failed, since it changed nothing" do
      expect {
        TimesheetEntry.transaction(requires_new: true) do
          TimesheetEntry.connection.execute("UPDATE \"timesheet_entries\" SET no_such_column = 1")
        end
      }.to raise_error(ActiveRecord::StatementInvalid)

      expect(single_writer_alerts).to be_empty
    end

    it "reports nothing when it is stood down" do
      allow(Rails.configuration.x.timekeeping).to receive(:single_writer_watch).and_return(false)

      bypass_write!

      expect(single_writer_alerts).to be_empty
    end

    it "never breaks the write it watches" do
      allow(Timekeeping::Ownership).to receive(:current).and_raise(RuntimeError, "unreadable")
      allow(Rails.logger).to receive(:warn).and_call_original

      bypass_write!

      expect(entry.reload.note).to eq("bypass")
      expect(Rails.logger).to have_received(:warn).with(a_string_including("could not check a write", "unreadable"))
    end

    it "allows any write inside .projection, and restores the flag after it" do
      Timekeeping::SingleWriterWatch.projection { bypass_write! }

      expect(single_writer_alerts).to be_empty
      expect(described_class.projection?).to be(false)
    end
  end

  describe "the shared write test" do
    it "matches what the CI guard matches, and nothing that only reads" do
      expect(described_class.write_sql?(%(INSERT INTO "timesheet_entries" ("id") VALUES (1)))).to be(true)
      expect(described_class.write_sql?(%(  update "timesheet_entries" SET note = 'x'))).to be(true)
      expect(described_class.write_sql?(%(DELETE FROM "timesheet_entries" WHERE id = 1))).to be(true)
      expect(described_class.write_sql?(%(SELECT * FROM "timesheet_entries"))).to be(false)
      expect(described_class.write_sql?(%(UPDATE "timesheet_entries_archive" SET x = 1))).to be(false)
      expect(described_class.write_sql?(nil)).to be(false)
    end
  end
end
