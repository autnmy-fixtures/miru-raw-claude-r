# frozen_string_literal: true

# The entry API's reads (docs/architecture/timekeeping-soa.md §5.2, §3.3 rule
# 1): the list and show a user makes right after writing, which read the owner
# of the entries, never the projection. Both answer only the kept entries of
# the token's company (§6.3). Who may read was decided by the caller, before
# the call (§6.2), so neither checks a role. A read writes nothing, so it
# needs no admission (§10.1).
class Internal::V1::EntriesController < Internal::BaseController
  CONTRACT = :entry_api

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
