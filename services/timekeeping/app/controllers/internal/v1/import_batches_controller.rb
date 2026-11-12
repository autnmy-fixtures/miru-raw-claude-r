# frozen_string_literal: true

# W5's Harvest import batches (docs/architecture/timekeeping-soa.md §3.4,
# §5.2): one mutating call per batch (EntryImport), named by its import id
# and batch number in the path.
class Internal::V1::ImportBatchesController < Internal::BaseController
  CONTRACT = :entry_api

  def create
    input = contract_input!("#/$defs/import_batch_request", request.request_parameters)
    write!(input) { EntryImport.call(input.fetch("rows"), claims) }
  end
end
