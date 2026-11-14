# frozen_string_literal: true

require "rails_helper"

# The recorded disposition of the pre-flight's unlocked links
# (docs/architecture/timekeeping-soa.md §10.4), resolved from invoice numbers
# per company name into the invoice ids the first cutover's checkpoint takes.
# The seed disposition itself is resolved on the real seed in
# spec/characterization/timekeeping/seed_preflight_spec.rb.
RSpec.describe Timekeeping::RecordedDisposition, type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-disposition")) }

  # The company factory names every company alike; a disposition names them.
  before do
    tenant_a.company.update!(name: "Fork & Leaf Salads")
    tenant_b.company.update!(name: "Copper Kettle Bakery")
  end

  let!(:first) { invoice_for(tenant_a, status: :sent) }
  let!(:second) { invoice_for(tenant_a, status: :sent) }
  let!(:other_tenants) { invoice_for(tenant_b, status: :sent) }

  after { FileUtils.rm_rf(directory) }

  def disposition_file(invoices, disposition: "active_without_edit_lock")
    directory.join("disposition.yml").tap do |path|
      path.write({ "unlocked_links" => { "disposition" => disposition, "invoices" => invoices } }.to_yaml)
    end
  end

  it "resolves every invoice number of every company into its invoice id" do
    path = disposition_file(
      {
        tenant_a.company.name => [first.invoice_number, second.invoice_number],
        tenant_b.company.name => [other_tenants.invoice_number]
      }
    )

    expect(described_class.unlocked_link_invoice_ids(path)).to eq([first.id, second.id, other_tenants.id])
  end

  it "reads a number of one company only from that company" do
    path = disposition_file({ tenant_b.company.name => [first.invoice_number] })

    expect { described_class.unlocked_link_invoice_ids(path) }
      .to raise_error(described_class::Unresolved, /#{Regexp.escape(first.invoice_number)} is not exactly one invoice/)
  end

  it "refuses a number no invoice has, resolving none of the others" do
    path = disposition_file({ tenant_a.company.name => [first.invoice_number, "NOPE-1"] })

    expect { described_class.unlocked_link_invoice_ids(path) }.to raise_error(described_class::Unresolved, /NOPE-1 is not exactly one invoice/)
  end

  it "refuses a number two companies of that name both hold" do
    twin = create(:company, name: tenant_a.company.name)
    create(:invoice, company: twin, client: create(:client, company: twin), invoice_number: first.invoice_number)
    path = disposition_file({ tenant_a.company.name => [first.invoice_number] })

    expect { described_class.unlocked_link_invoice_ids(path) }.to raise_error(described_class::Unresolved, /not exactly one invoice/)
  end

  it "refuses a disposition §10.4 does not define for an unlocked link" do
    path = disposition_file({ tenant_a.company.name => [first.invoice_number] }, disposition: "released")

    expect { described_class.unlocked_link_invoice_ids(path) }.to raise_error(described_class::Unresolved, /"released", expected active_without_edit_lock/)
  end

  it "reads the seed disposition by default" do
    expect { described_class.unlocked_link_invoice_ids }.to raise_error(described_class::Unresolved, /seed_disposition.yml: .* CK-0001 is not exactly one invoice/)
  end
end
