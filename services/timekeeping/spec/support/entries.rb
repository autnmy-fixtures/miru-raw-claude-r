# frozen_string_literal: true

# Entries and reservations as a checkpoint would load them (§10.5 step 4):
# rows written directly, with the ids, tenants and versions they carry.
module EntryRows
  def entry!(company_id:, **attributes)
    Entry.create!(
      { company_id:, project_id: 10 + company_id, user_id: 7, duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled" }
        .merge(attributes)
    )
  end

  def reservation!(entry, invoice_id:, state: "committed", disposition: "active", edit_lock: true)
    entry.reservations.create!(
      invoice_id:, company_id: entry.company_id, state:, disposition:, edit_lock:,
      operation_id: (SecureRandom.uuid if state == "provisional")
    )
  end
end

RSpec.configure { |config| config.include EntryRows }
