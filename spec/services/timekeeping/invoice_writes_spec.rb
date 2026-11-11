# frozen_string_literal: true

require "rails_helper"

# Timekeeping::InvoiceWrites: the invoice writes run through the reservation
# boundary (docs/architecture/timekeeping-soa.md §3.1 W7). The endpoints are
# covered in spec/requests/timekeeping/invoice_reservation_writes_spec.rb;
# this covers what they cannot reach: a desired set worked out from lines
# that changed before the save ran.
RSpec.describe Timekeeping::InvoiceWrites do
  include TimekeepingCharacterization::Helpers

  subject(:writes) { described_class.new(boundary: Timekeeping::InvoiceBoundary.new(pause: ->(_attempt) { })) }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:tenant) { build_tenant }
  let(:entry) { unbilled_entry(tenant) }
  let(:invoice) { invoice_for(tenant) }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  before do
    direct_line(invoice, entry)
    fake.seed_entry(company_id: tenant.company.id, id: entry.id, project_id: entry.project_id, user_id: entry.user_id,
      duration: entry.duration, work_date: entry.work_date.iso8601)
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
  end

  after { expect(fake.violations).to be_empty }

  it "refuses, as retryable, a save that leaves other entries than the owner prepared, and rolls it back" do
    # The first read of the lines, before the save, misses the persisted one,
    # as if another write added it after the desired set was worked out.
    reads = 0
    allow(Timekeeping::InvoiceDesiredSet).to receive(:lines_of).and_wrap_original do |original, invoice|
      (reads += 1) == 1 ? [] : original.call(invoice)
    end

    expect { writes.update(invoice, { "reference" => "stale" }) }.to raise_error(
      an_instance_of(Timekeeping::InvoiceBoundary::Failed).and(having_attributes(reason: :desired_set_changed, retryable: true))
    )
    expect(invoice.reload.reference).not_to eq("stale")
    expect(Timekeeping::InvoiceOperation.sole).to have_attributes(state: "failed", entry_ids: [])
  end

  it "saves when the lines the save leaves are the desired set" do
    expect(writes.update(invoice, { "reference" => "kept" })).to eq(invoice)

    expect(invoice.reload.reference).to eq("kept")
    expect(Timekeeping::InvoiceOperation.sole).to have_attributes(state: "succeeded", entry_ids: [entry.id])
  end
end
