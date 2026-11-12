# frozen_string_literal: true

# Invoice candidate selection (docs/architecture/timekeeping-soa.md §5.2,
# §3.3 rule 1): the entries of the token's company (§6.3) an invoice may take,
# as CandidateList selects them. Who may select candidates was decided by the
# caller, before the call (InvoiceLineItemPolicy there), so it checks no role.
# A read writes nothing, so it needs no admission (§10.1).
class Internal::V1::CandidatesController < Internal::BaseController
  CONTRACT = :entry_api

  def index
    query = contract_input!("#/$defs/candidates_query", request.query_parameters)
    render json: CandidateList.call(Entry.of_company(claims.fetch("company_id")).kept, query)
  end
end
