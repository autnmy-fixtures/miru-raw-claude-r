# frozen_string_literal: true

# Two-tenant fixtures for the Timekeeping characterization specs
# (docs/architecture/timekeeping-soa.md §12.1). Each tenant is a separate
# company with its own billable project, an admin and an employee who is a
# member of that project. The specs pin today's behaviour on tenant A and
# assert tenant B is untouched.
module TimekeepingCharacterization
  Tenant = Data.define(:company, :client, :project, :admin, :employee)

  module Helpers
    def build_tenant
      company = create(:company)
      client = create(:client, company:)
      project = create(:project, client:, billable: true)
      admin = member_of(company, role: :admin)
      employee = member_of(company, role: :employee)
      create(:project_member, project:, user: employee)

      Tenant.new(company:, client:, project:, admin:, employee:)
    end

    def member_of(company, role:)
      create(:user, current_workspace_id: company.id).tap do |user|
        create(:employment, company:, user:)
        user.add_role(role, company)
      end
    end

    def unbilled_entry(tenant, user: tenant.employee, **attributes)
      create(:timesheet_entry, user:, project: tenant.project, bill_status: :unbilled, **attributes)
    end

    def invoice_for(tenant, status: :draft)
      create(:invoice, company: tenant.company, client: tenant.client, status:)
    end

    def direct_line(invoice, entry, rate: 100)
      create(:invoice_line_item, invoice:, timesheet_entry: entry, quantity: entry.duration.to_i, rate:)
    end

    # A project aggregate line: no direct entry, its entries linked through
    # invoice_line_item_time_entries, as GenerateInvoice::NewLineItemsService
    # suggests when grouping by project.
    def grouped_line(invoice, entries, rate: 100)
      line = create(:invoice_line_item, invoice:, timesheet_entry: nil, quantity: entries.sum(&:duration).to_i, rate:)
      entries.each { |entry| create(:invoice_line_item_time_entry, invoice_line_item: line, timesheet_entry: entry) }
      line
    end

    def locked?(entry)
      entry.reload.locked
    end
  end
end

RSpec.shared_context "with two Timekeeping tenants" do
  include TimekeepingCharacterization::Helpers

  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let!(:bystander_entry) { unbilled_entry(tenant_b) }

  after { expect(locked?(bystander_entry)).to be(false), "tenant B's entry must not be touched" }
end
