# frozen_string_literal: true

require "rails_helper"

# The paused step of the billing-handoff proof (Timekeeping::BillingHandoffCheck;
# docs/architecture/timekeeping-soa.md §12.4, "Billing writes during a
# handoff"), across connections, as bin/timekeeping-demo billing-handoff runs
# it against the demo: the billing write holds its transaction open, a
# handoff's step 1 (Timekeeping::HandoffFence's close) on another connection
# waits on it, and only the release lets the write commit and the close
# through.
#
# The other connections cannot see the example's own transaction, so the two
# tenants and the ownership row are committed from a connection of their own,
# and every table is emptied afterwards. The example's own connection only
# reads, so it holds no lock that would keep that from happening; it reads
# what the others committed, as the pool has room for three connections at
# once.
RSpec.describe "Timekeeping billing-handoff proof: the paused billing write, across connections", type: :model do
  include TimekeepingConnections
  include TimekeepingCharacterization::Helpers

  let(:directory) { Dir.mktmpdir("billing-handoff") }
  let(:run_name) { "20261116T120000Z-ab12" }
  let(:log) { StringIO.new }

  # Committed: the two tenants, as the seeded businesses are, and Timekeeping
  # owning the entries with admission open.
  let!(:tenants) do
    run_on_own_connection do
      Timekeeping::Ownership.create!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
      2.times.map do |index|
        tenant = build_tenant
        tenant.company.update!(name: "Billing handoff business #{index + 1}")
        { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email, company_id: tenant.company.id }
      end
    end
  end

  after do
    FileUtils.rm_rf(directory)
    run_on_own_connection { DatabaseCleaner.clean_with(:deletion, except: %w[ar_internal_metadata schema_migrations]) }
  end

  def check(wait: 5)
    Timekeeping::BillingHandoffCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport: ->(_) { raise "no request expected" }),
      password: "unused", run: run_name, logger: Logger.new(log),
      options: Timekeeping::BillingHandoffCheck::Options.new(wait:, tenants: tenants.map { |tenant| tenant.except(:company_id) }, directory:)
    )
  end

  def marker(name) = Pathname(directory).join(run_name, name)

  def wait_for(name)
    (wait_seconds * 10).times do
      return true if marker(name).exist?

      sleep 0.1
    end
    raise "timed out waiting for the #{name} marker"
  end

  def ownership = Timekeeping::Ownership.current.summary

  it "holds the billing write open until the handoff's close waits on it, then commits it before the close goes through" do
    paused = on_own_connection { check.paused }
    wait_for("admitted")
    close = on_own_connection { Timekeeping::HandoffFence.call(:close, generation: 1).summary }
    wait_for("waiting")

    aggregate_failures do
      expect(ownership).to eq("generation 1, owner timekeeping, state open")
      expect(close).to be_alive
      expect(Invoice.count).to eq(0)
    end

    marker("release").write("")
    paused.value

    expect(close.value).to eq("generation 2, owner timekeeping, state closed")
    state = JSON.parse(marker("state.json").read)
    expect(state).to include("owner" => "timekeeping", "generation" => 1)
    invoices = Invoice.where(id: state["invoices"].pluck("invoice_id")).order(:id)
    expect(invoices.map(&:company_id)).to eq(tenants.pluck(:company_id))
    expect(invoices.map { |invoice| [invoice.status, invoice.amount, invoice.amount_paid, invoice.amount_due] })
      .to all(eq(["sent", 220, 50, 170]))
    expect(invoices.map { |invoice| [invoice.invoice_line_items.count, invoice.invoice_taxes.count, invoice.payments.count] })
      .to all(eq([1, 1, 1]))
    expect(log.string).to include(
      "holding the ownership row FOR SHARE",
      "waits on this billing write, and ownership is still generation 1, owner timekeeping, state open",
      "the paused billing write committed, and only then did the handoff close admission (generation 2, owner timekeeping, " \
      "state closed), on 2 businesses"
    )
  ensure
    marker("release").write("") if marker("release").dirname.exist?
    paused&.join
    close&.join
  end

  it "rolls the billing write back, and writes nothing, when no handoff comes to wait on it" do
    expect { check(wait: 1).paused }.to raise_error(
      Timekeeping::BillingHandoffCheck::Failed, /timed out after 1 s waiting until the handoff's step 1 waits on this billing write/
    )

    expect([Invoice.count, Payment.count]).to eq([0, 0])
    expect(ownership).to eq("generation 1, owner timekeeping, state open")
    expect(marker("waiting")).not_to exist
  end

  it "refuses to start while a handoff has admission closed" do
    run_on_own_connection { Timekeeping::Ownership.current.update!(state: "closed", generation: 2) }

    expect { check.paused }.to raise_error(Timekeeping::BillingHandoffCheck::Failed, /starts with admission open/)
    expect(Invoice.count).to eq(0)
  end
end
