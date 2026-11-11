# frozen_string_literal: true

# Runs one sweep of the invoice operation worker
# (docs/architecture/timekeeping-soa.md §11.1) on its own queue, next to
# `default` as `billing_sync` is, so the worker can run while the `default`
# worker is not started. The dispatcher schedules it every few seconds in
# config/solid_queue.yml; every sweep is safe to repeat or overlap, because
# recovery locks each intent and delivery is idempotent by operation.
class Timekeeping::InvoiceOperationsJob < ApplicationJob
  queue_as :invoice_operations

  def perform
    Timekeeping::InvoiceOperationWorker.new.run
  end
end
