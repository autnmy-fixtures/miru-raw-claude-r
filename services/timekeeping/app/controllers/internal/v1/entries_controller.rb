# frozen_string_literal: true

# The entry API (docs/architecture/timekeeping-soa.md §5.2).
#
# Its reads (§3.3 rule 1): the list and show a user makes right after
# writing, which read the owner of the entries, never the projection. Both
# answer only the kept entries of the token's company (§6.3). Who may read was
# decided by the caller, before the call (§6.2), so neither checks a role. A
# read writes nothing, so it needs no admission (§10.1).
#
# Its writes: create (EntryCreate), update (EntryUpdate) and discard
# (EntryDiscard), one mutating call each (EntryWrite).
class Internal::V1::EntriesController < Internal::BaseController
  CONTRACT = :entry_api

  def create
    input = contract_input!("#/$defs/entry_create_request", request.request_parameters)
    write!(input) { EntryCreate.call(input.fetch("entry"), claims) }
  end

  def update
    input = contract_input!("#/$defs/entry_update_request", request.request_parameters)
    write!(input) { EntryUpdate.call(params[:id], input.fetch("entry"), claims) }
  end

  def destroy
    input = contract_input!("#/$defs/empty_request", request.request_parameters)
    write!(input) { EntryDiscard.call(params[:id], claims) }
  end

  def index
    query = contract_input!("#/$defs/list_query", request.query_parameters)
    render json: EntryList.page(Entry.of_company(claims.fetch("company_id")).kept, query)
  rescue EntryList::BadCursor => error
    refuse!("invalid-request", 400, error.message)
  end

  def show
    entry = Entry.of_company(claims.fetch("company_id")).kept.includes(:reservations).find_by(id: params[:id])
    refuse!("not-found", 404, "no entry #{params[:id]} in this company") unless entry

    render json: { "entry" => entry.to_contract }
  end
end
