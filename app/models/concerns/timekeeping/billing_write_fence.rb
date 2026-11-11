# frozen_string_literal: true

# The billing-write fence of docs/architecture/timekeeping-soa.md §10.1:
# "Every billing write transaction in the existing application (invoice, line
# item, invoice tax, payment, mobile-collection payment included) takes
# FOR SHARE on the local ownership row and reads state under that lock."
#
# Included in each billing model, so every write path that saves or destroys
# one of them (controllers, nested attributes, payment services, webhooks,
# jobs, mobile collections) passes the fence inside the write's own
# transaction. A handoff that raises the generation therefore waits for every
# billing write already admitted, and a billing write that arrives while
# admission is not open is refused with a retryable 503 ownership-moving.
# Nothing is written, because the refusal rolls back the whole transaction.
# That keeps the financial snapshot (§10.4) free of billing writes.
#
# Writes that skip model callbacks are fenced too where the models use them:
# update_columns (and so update_column), which the payment and invoice
# mailers use to stamp when mail was sent. Relation-level writes
# (update_all, delete_all, insert_all) skip every model hook; nothing in app/
# issues one against a billing table.
module Timekeeping::BillingWriteFence
  extend ActiveSupport::Concern

  included do
    # Prepended, so a refused write is refused before any other callback
    # does work, dependent destroys included.
    before_save :admit_billing_write, prepend: true
    before_destroy :admit_billing_write, prepend: true
  end

  def update_columns(attributes)
    self.class.transaction do
      admit_billing_write
      super
    end
  end

  private

    def admit_billing_write
      Timekeeping::Ownership.admit!
    end
end
