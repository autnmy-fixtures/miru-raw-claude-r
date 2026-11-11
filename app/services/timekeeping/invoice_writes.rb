# frozen_string_literal: true

# The invoice writes that change a reservation set (docs/architecture/
# timekeeping-soa.md §3.1 W7, §7.2), each run through the invoice reservation
# boundary: create and update are a save, a single delete is a discard, and a
# bulk delete is a destroy (§1.4). Controllers authorize as today, then call
# one of these instead of writing the invoice themselves.
#
# Under `legacy` the boundary runs the write as today and today's lock
# callbacks decide (§3.1), so nothing changes. Under any other owner the
# callbacks stand down and the owner holds the reservations: the write runs
# only after the owner prepared its desired set, inside the transaction that
# records success, and the desired set is checked against what the write left
# behind before it commits.
class Timekeeping::InvoiceWrites
  LINES = "invoice_line_items_attributes"

  def initialize(boundary: Timekeeping::InvoiceBoundary.new)
    @boundary = boundary
  end

  # The invoice id is taken from invoices_id_seq before the intent, so the
  # intent and prepare name the invoice the save then creates (§9.1).
  def create(company, attributes)
    attributes = attributes.to_h.stringify_keys
    id = next_invoice_id
    status = attributes.fetch("status") { Invoice.new.status }
    desired = Timekeeping::InvoiceDesiredSet.after([], attributes[LINES])

    save(change(id, company.id, :save, status, desired)) do
      company.invoices.create!(attributes.merge("id" => id))
    end
  end

  def update(invoice, attributes)
    attributes = attributes.to_h.stringify_keys
    status = attributes.fetch("status") { invoice.status }
    desired = Timekeeping::InvoiceDesiredSet.after(Timekeeping::InvoiceDesiredSet.lines_of(invoice), attributes[LINES])

    save(change(invoice.id, invoice.company_id, :save, status, desired)) do
      invoice.tap { invoice.update!(attributes) }
    end
  end

  # A single delete is soft (§1.4).
  def discard(invoice)
    @boundary.run(change(invoice.id, invoice.company_id, :discard, invoice.status)) { invoice.discard! }.value
  end

  # A bulk delete is hard (§1.4). False when the invoice refuses to go, as
  # one with recorded payments does: the reservations stay as they were.
  def destroy(invoice)
    @boundary.run(change(invoice.id, invoice.company_id, :destroy, invoice.status)) { invoice.destroy! }
    true
  rescue ActiveRecord::RecordNotDestroyed
    false
  end

  private

    def change(invoice_id, company_id, kind, status, entry_ids = [])
      Timekeeping::InvoiceBoundary::Change.new(
        invoice_id:, company_id:, kind:, entry_ids:,
        invoice_state: Timekeeping::InvoiceDesiredSet.invoice_state(status)
      )
    end

    # `prepared` is nil under `legacy`, where today's callbacks and today's
    # line-item checks decide. Under an owner, the line-item checks read the
    # entries it prepared (Timekeeping::EntryReferences, L8).
    def save(change, &write)
      @boundary.run(change) do |prepared|
        next write.call if prepared.nil?

        Timekeeping::EntryReferences.within(prepared, &write).tap { |invoice| left_as_desired!(invoice, change) }
      end.value
    end

    # The desired set was worked out before the save, from the lines as they
    # were then. Any other change to the lines since then, or any way the
    # save read the posted lines differently, would commit a reservation set
    # the invoice does not hold. That is refused, and the save rolls back.
    def left_as_desired!(invoice, change)
      held = Timekeeping::InvoiceDesiredSet.referenced(invoice)
      return if held == change.entry_ids.sort

      raise Timekeeping::InvoiceBoundary::Failed.new(
        reason: :desired_set_changed, retryable: true,
        detail: "invoice #{invoice.id} references #{held.inspect}, prepared #{change.entry_ids.sort.inspect}"
      )
    end

    def next_invoice_id
      Invoice.connection.select_value("SELECT nextval(pg_get_serial_sequence('invoices', 'id'))")
    end
end
