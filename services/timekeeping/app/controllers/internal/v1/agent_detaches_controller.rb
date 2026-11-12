# frozen_string_literal: true

# W6's agent detach (docs/architecture/timekeeping-soa.md §3.1, §5.2): one
# mutating call (EntryDetach), named by the agent's id in the path. The
# existing application deletes the agent row only after this answers (§3.4).
class Internal::V1::AgentDetachesController < Internal::BaseController
  CONTRACT = :entry_api

  def create
    input = contract_input!("#/$defs/empty_request", request.request_parameters)
    write!(input) { EntryDetach.call(Integer(params[:agent_id], 10), claims) }
  end
end
