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
      resources :candidates, only: :index
    end
  end
end
