# frozen_string_literal: true

class InvoiceLineItemTimeEntry < ApplicationRecord
  include Timekeeping::BillingWriteFence

  belongs_to :invoice_line_item
  # Required, as before, but checked through Timekeeping::EntryReferences: the
  # entries table, or inside an owner's prepared save the owner (L8), so a link
  # can name an entry the projection does not hold yet.
  belongs_to :timesheet_entry, optional: true
  validate :timesheet_entry_exists_in_invoice_company

  validates :timesheet_entry_id, uniqueness: { scope: :invoice_line_item_id }

  private

    def timesheet_entry_exists_in_invoice_company
      entry = Timekeeping::EntryReferences.current.find([timesheet_entry_id])[timesheet_entry_id]
      return errors.add(:timesheet_entry, :blank, message: :required) if entry.nil?

      invoice = invoice_line_item&.invoice
      return if invoice.blank? || entry.company_id == invoice.company_id

      errors.add(:timesheet_entry, "must belong to the same company")
    end
end
