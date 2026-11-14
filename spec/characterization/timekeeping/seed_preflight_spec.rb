# frozen_string_literal: true

require "rails_helper"

# The two-tenant seed fixtures of docs/architecture/timekeeping-soa.md §14
# ("Foundation, per lane") and §10.4: on the data db/seeds.rb builds for Fork &
# Leaf Salads and Copper Kettle Bakery, the pre-flight lists no orphan and no
# conflict, and its unlocked links are exactly the recorded seed disposition.
RSpec.describe "Timekeeping characterization: pre-flight on the seeded businesses", type: :model do
  let(:disposition) { YAML.load_file(Rails.root.join("spec/fixtures/timekeeping/seed_disposition.yml")) }

  # Loads the seed wrapped, so its helper methods and constants stay out of the
  # global namespace, and restores the Faker generator it reseeds.
  def seed_both_businesses!
    stdout = $stdout
    faker_random = Faker::Config.random
    $stdout = StringIO.new
    load Rails.root.join("db/seeds.rb").to_s, true
  ensure
    $stdout = stdout
    Faker::Config.random = faker_random
  end

  def invoice_numbers_by_company(entries)
    Invoice.where(id: entries.flat_map(&:kept_invoice_ids)).includes(:company)
      .group_by { |invoice| invoice.company.name }
      .transform_values { |invoices| invoices.map(&:invoice_number).sort }
  end

  it "lists no orphan or conflict, and exactly the recorded unlocked links" do
    seed_both_businesses!

    report = Timekeeping::Preflight.process

    aggregate_failures do
      expect(Company.where(id: report.entries.map(&:company_id).uniq).pluck(:name))
        .to contain_exactly("Fork & Leaf Salads", "Copper Kettle Bakery")
      expect(report.orphans).to be_empty
      expect(report.conflicts).to be_empty
      expect(invoice_numbers_by_company(report.unlocked_links))
        .to eq(disposition.fetch("unlocked_links").fetch("invoices"))
    end
  end

  # §10.4: "the cutover checks every list again on the live data". With the
  # recorded disposition, the first cutover's checkpoint (§10.5 step 4) is
  # taken with nothing listed, and carries every entry and one reservation for
  # each entry on a kept invoice, locked exactly as today. This application's
  # side of the reconcile (§10.5 step 6) then passes on it.
  it "takes the first cutover's checkpoint with the recorded disposition, and reconciles it" do
    seed_both_businesses!
    recorded = Timekeeping::RecordedDisposition.unlocked_link_invoice_ids
    on_kept_invoices = Timekeeping::Preflight.process.entries.select { |entry| entry.mapping == :active }
    money_before = Timekeeping::FinancialSnapshot.process
    set_timekeeping_ownership!(generation: 1, owner: "legacy", state: "frozen")

    checkpoint = Timekeeping::LegacyCheckpoint.take(generation: 1, unlocked_link_invoice_ids: recorded)

    aggregate_failures do
      expect(recorded.size).to eq(disposition.fetch("unlocked_links").fetch("invoices").values.sum(&:size))
      expect(checkpoint.entries.map { |entry| entry.fetch("id") }).to eq(TimesheetEntry.order(:id).ids)
      expect(checkpoint.reservations.map(&:entry_id)).to match_array(on_kept_invoices.map(&:entry_id))
      expect(checkpoint.reservations.map(&:disposition).uniq).to eq([:active])
      expect(checkpoint.entries.to_h { |entry| [entry.fetch("id"), entry.fetch("locked")] })
        .to eq(TimesheetEntry.pluck(:id, :locked).to_h)
    end

    # §10.5 step 6 on this side: once the relay has delivered the snapshot the
    # load writes for every entry, this application's tables reconcile with
    # the checkpoint exactly, and no billing value has moved.
    relay = TimekeepingContracts::FakeRelay.new
    snapshots = checkpoint.entries.map do |entry|
      relay.snapshot(
        entry_id: entry.fetch("id"), version: entry.fetch("version"), company_id: entry.fetch("company_id"),
        **entry.except("id", "version", "company_id").symbolize_keys
      )
    end
    Timekeeping::ProjectionConsumer.process(snapshots)

    expect(Timekeeping::CheckpointReconcile.call(generation: 1, entries: checkpoint.entries, reservations: checkpoint.reservations, financial_snapshot: money_before))
      .to eq(Timekeeping::CheckpointReconcile::Reconciled.new(entries: TimesheetEntry.count, reservations: on_kept_invoices.size))
  end

  # §10.2 step 5 on the live seed: the handoff tool runs the whole first
  # cutover on both copies of the ownership record, against the consumer-side
  # fake of Timekeeping's handoff API, whose relay delivers into the real
  # projection endpoint. Both sides reconcile, no billing value moves, and
  # both copies end open under Timekeeping at generation 1.
  it "runs the first cutover on both seeded businesses with the recorded disposition" do
    seed_both_businesses!
    allow(Rails.configuration.x.timekeeping).to receive(:token_key).and_return(TimekeepingContracts::TEST_TOKEN_KEY)
    fake = TimekeepingContracts::FakeHandoff.new.install!
    recorded = Timekeeping::RecordedDisposition.unlocked_link_invoice_ids
    on_kept_invoices = Timekeeping::Preflight.process.entries.count { |entry| entry.mapping == :active }
    money_before = Timekeeping::FinancialSnapshot.process
    locked_before = TimesheetEntry.pluck(:id, :locked).to_h

    result = Timekeeping::FirstCutover.new(
      client: Timekeeping::HandoffClient.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY),
      unlocked_link_invoice_ids: recorded, drain: Timekeeping::FirstCutover::Drain.new(pause: ->(_) { fake.relay! }),
      logger: Logger.new(nil)
    ).call

    aggregate_failures do
      expect(result).to eq(Timekeeping::FirstCutover::Result.new(generation: 1, entries: TimesheetEntry.count, reservations: on_kept_invoices))
      expect(Timekeeping::Ownership.current.slice(:generation, :owner, :state)).to eq("generation" => 1, "owner" => "timekeeping", "state" => "open")
      expect(fake.copy).to eq(TimekeepingContracts::FakeHandoff::Copy.new(generation: 1, owner: "timekeeping", state: "open"))
      expect(fake.violations).to be_empty
      expect(TimesheetEntry.distinct.pluck(:version)).to eq([1])
      expect(TimesheetEntry.pluck(:id, :locked).to_h).to eq(locked_before)
      expect(Timekeeping::FinancialSnapshot.diff(money_before, Timekeeping::FinancialSnapshot.process)).to be_empty
    end
  end
end
