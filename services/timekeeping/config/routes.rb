# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness for the local demo runtime (§11.2): 200 once the app has booted.
  get "up" => "rails/health#show", as: :rails_health_check

  # The internal API (docs/architecture/timekeeping-soa.md §5), one route per
  # contract operation as it lands. Ids are the contract's id_param.
  namespace :internal do
    namespace :v1 do
      # PATCH only: the contract has no PUT (entry_api.json update_entry).
      resources :entries, only: %i[index show create destroy], constraints: { id: /[1-9][0-9]*/ }
      patch "entries/:id", to: "entries#update", constraints: { id: /[1-9][0-9]*/ }
      post "entries/bulk_move", to: "entries#bulk_move"
      post "entries/bulk_discard", to: "entries#bulk_discard"
      post "imports/:import_id/batches/:n", to: "import_batches#create", constraints: { n: /[1-9][0-9]*/ }
      post "agents/:agent_id/detach", to: "agent_detaches#create", constraints: { agent_id: /[1-9][0-9]*/ }
      resources :candidates, only: :index

      # The reservation API (reservation_api.json): prepare, commit and abort
      # of one (invoice, operation).
      scope "invoices/:invoice_id/operations/:operation_id", constraints: { invoice_id: /[1-9][0-9]*/, operation_id: /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/ } do
        post "prepare", to: "invoice_operations#prepare_operation"
        post "commit", to: "invoice_operations#commit_operation"
        post "abort", to: "invoice_operations#abort_operation"
      end

      # The handoff API (handoff_api.json): the handoff tool's way to
      # Timekeeping's copy of the ownership record and the checkpoint (§10.5).
      # A step is one the shared state machine names; any other is not found.
      get "handoff", to: "handoffs#show"
      post "handoff/steps/:step", to: "handoffs#step",
        constraints: { step: Regexp.union(TimekeepingReservations::Handoff::STEPS.keys.map(&:to_s)) }
      post "handoff/checkpoint", to: "handoffs#load_checkpoint"
      post "handoff/checkpoint/reconcile", to: "handoffs#reconcile_checkpoint"
    end
  end
end
