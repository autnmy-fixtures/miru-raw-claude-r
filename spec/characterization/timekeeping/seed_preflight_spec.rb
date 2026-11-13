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
  # each entry on a kept invoice, locked exactly as today.
  it "takes the first cutover's checkpoint with the recorded disposition" do
    seed_both_businesses!
    recorded = disposition.fetch("unlocked_links").fetch("invoices").flat_map do |company, numbers|
      Invoice.joins(:company).where(companies: { name: company }, invoice_number: numbers).ids
    end
    on_kept_invoices = Timekeeping::Preflight.process.entries.select { |entry| entry.mapping == :active }
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
  end
end
