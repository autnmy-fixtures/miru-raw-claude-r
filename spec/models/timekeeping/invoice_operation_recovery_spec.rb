# frozen_string_literal: true

require "rails_helper"

# Recovery against a save in progress, across connections
# (docs/architecture/timekeeping-soa.md §9.2): "It takes the intent row FOR
# UPDATE, which waits for any step-3 transaction still in progress. ... If it
# changes no row, the save already committed and recovery leaves it alone."
#
# The other connections cannot see the example's own transaction, so every
# row here is committed from a connection of its own and deleted afterwards.
RSpec.describe "Timekeeping invoice operation recovery across connections", type: :model do
  include TimekeepingConnections

  after do
    run_on_own_connection do
      Timekeeping::InvoiceOperation.delete_all
      Timekeeping::Ownership.delete_all
    end
  end

  def open_intent
    run_on_own_connection { Timekeeping::InvoiceOperation.open!(invoice_id: 501, company_id: 42, kind: :save, entry_ids: [101]) }
  end

  # Step 3 of a save: records success in the invoice transaction and holds it
  # open until `finish` is given, then commits or, with :rollback, rolls back.
  def save_in_progress(intent, recorded, finish)
    on_own_connection do
      ActiveRecord::Base.transaction do
        intent.succeed!
        recorded << true
        raise ActiveRecord::Rollback if take(finish) == :rollback
      end
    end
  end

  # Recovery on a connection of its own; answers the durable outcome once the
  # step-3 transaction lets it read the row.
  def recovery(intent, pid)
    on_own_connection do |connection|
      pid << connection.select_value("SELECT pg_backend_pid()")
      Timekeeping::InvoiceOperation.find(intent.id).record_failure!
    end
  end

  { commit: "succeeded", rollback: "failed" }.each do |save_ends, outcome|
    it "waits for a save's step-3 transaction, and answers #{outcome} when the save ends in #{save_ends}" do
      intent = open_intent
      recorded = Queue.new
      finish = Queue.new
      pid = Queue.new
      save = save_in_progress(intent, recorded, finish)
      take(recorded)

      recovering = recovery(intent, pid)
      waited = wait_until_waiting_on_lock(ActiveRecord::Base.connection, take(pid))
      finish << save_ends
      save.join

      aggregate_failures do
        expect(waited).to be(true), "recovery never waited on the save's transaction"
        expect(recovering.value).to eq(outcome)
        expect(run_on_own_connection { intent.reload.state }).to eq(outcome)
      end
    ensure
      finish << :rollback
      save&.join
    end
  end
end
