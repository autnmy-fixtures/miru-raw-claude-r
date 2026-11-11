# frozen_string_literal: true

class InvoiceLineItem < ApplicationRecord
  include Timekeeping::BillingWriteFence

  belongs_to :invoice
  belongs_to :timesheet_entry, optional: true
  has_many :invoice_line_item_time_entries, dependent: :destroy
  has_many :linked_timesheet_entries, through: :invoice_line_item_time_entries, source: :timesheet_entry

  before_update :capture_previous_invoice_id, if: :will_save_change_to_invoice_id?
  before_destroy :unlock_timesheet_entries
  after_save :sync_invoice_totals
  after_destroy :sync_invoice_totals

  validates :name, :date, :rate, :quantity, presence: true
  validates :rate, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity, numericality: { greater_than_or_equal_to: 0 }
  # No foreign key ties a line to its entry (docs/architecture/timekeeping-soa.md
  # §10.2 step 3), so an id naming no entry is refused here, with the message
  # belongs_to gives a grouped line's required link (InvoiceLineItemTimeEntry).
  # What an entry is, and its company, come from Timekeeping::EntryReferences:
  # the entries table, or inside an owner's prepared save the owner (L8).
  validate :timesheet_entry_exists_in_invoice_company, if: :timesheet_entry_id?
  validate :linked_timesheet_entries_belong_to_invoice_company

  def self.total_cost_of_all_line_items
    (self.sum("quantity * rate") / 60.0).round(3)
  end

  def hours_spent
    @_hours_spent ||= quantity.to_f / 60.0
  end

  def minutes_spent
    @_minutes_spent ||= quantity.to_f % 60.0
  end

  def time_spent
    if quantity <= 0
      "00:00"
    else
      hours = hours_spent.to_i
      hours = "0#{hours}" if hours.digits.count == 1

      minutes = minutes_spent.to_i
      minutes = "0#{minutes}" if minutes.digits.count == 1

      "#{hours}:#{minutes}"
    end
  end

  def total_cost
    @_total_cost ||= (hours_spent * rate).round(3)
  end

  def formatted_date
    CompanyDateFormattingService.new(date, company: invoice.company).process
  end

  # The grouped line's entries, read from its own join rows, never from the
  # entries they name (Timekeeping::EntryReferences). As has_many ids readers
  # do: the rows in memory when there are any, else one pluck.
  def linked_timesheet_entry_ids
    rows = association(:invoice_line_item_time_entries)
    return rows.scope.pluck(:timesheet_entry_id) unless rows.loaded? || rows.target.any?

    rows.load_target.map(&:timesheet_entry_id)
  end

  def linked_timesheet_entry_ids=(ids)
    Timekeeping::EntryReferences.current.link(self, ids)
  end

  private

    def entry_references(ids)
      Timekeeping::EntryReferences.current.find(ids).values
    end

    def timesheet_entry_exists_in_invoice_company
      entry = entry_references([timesheet_entry_id]).first
      return errors.add(:timesheet_entry, :blank, message: :required) if entry.nil?
      return if invoice.blank? || entry.company_id == invoice.company_id

      errors.add(:timesheet_entry, "must belong to the same company")
    end

    def linked_timesheet_entries_belong_to_invoice_company
      return if invoice.blank?
      return if entry_references(linked_timesheet_entry_ids).all? { |entry| entry.company_id == invoice.company_id }

      errors.add(:linked_timesheet_entries, "must belong to the same company")
    end

    def unlock_timesheet_entries
      return unless invoice.draft? && Timekeeping::Ownership.reservations_by_callbacks?

      entries = TimesheetEntry.where(id: associated_timesheet_entry_ids)
      Timekeeping::Gateway.call(Timekeeping::Gateway::SetLocked.new(entries:, locked: false))
    end

    def associated_timesheet_entry_ids
      ([timesheet_entry_id] + linked_timesheet_entry_ids).compact.uniq
    end

    def capture_previous_invoice_id
      @previous_invoice_id = invoice_id_was
    end

    def sync_invoice_totals
      return unless should_sync_invoice_totals?

      invoice_ids_to_sync.each do |current_invoice_id|
        next if skip_invoice_sync?(current_invoice_id)

        invoice = Invoice.find_by(id: current_invoice_id)
        next unless invoice

        invoice.sync_totals_from_line_items!
      end
    ensure
      @previous_invoice_id = nil
    end

    def should_sync_invoice_totals?
      destroyed? ||
        previous_changes.key?("id") ||
        previous_changes.key?("invoice_id") ||
        previous_changes.key?("quantity") ||
        previous_changes.key?("rate")
    end

    def invoice_ids_to_sync
      ids = [invoice_id]
      ids << @previous_invoice_id if defined?(@previous_invoice_id)
      ids << previous_changes.dig("invoice_id", 0)
      ids.compact.uniq
    end

    def skip_invoice_sync?(current_invoice_id)
      invoice.present? &&
        invoice.id == current_invoice_id &&
        invoice.skip_line_item_total_sync
    end
end
