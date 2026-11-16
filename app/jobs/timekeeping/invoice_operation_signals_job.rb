# frozen_string_literal: true

# Reads the invoice operation ledger's signals of
# docs/architecture/timekeeping-soa.md §11.3, pending intents and undelivered
# commits and aborts older than 60 s (Timekeeping::Signals::INVOICE_OPERATIONS),
# and reports their alerts. It runs on the relay worker's queue, not
# `invoice_operations`, so an invoice operation worker that stops is still
# noticed (§11.1: only the two dedicated workers run). The dispatcher
# schedules it in config/solid_queue.yml.
class Timekeeping::InvoiceOperationSignalsJob < ApplicationJob
  queue_as :timekeeping_relay

  def perform
    Timekeeping::Signals.new.report!(Timekeeping::Signals::INVOICE_OPERATIONS)
  end
end
