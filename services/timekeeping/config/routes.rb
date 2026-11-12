# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness for the local demo runtime (§11.2): 200 once the app has booted.
  get "up" => "rails/health#show", as: :rails_health_check

  # The internal API (docs/architecture/timekeeping-soa.md §5), one route per
  # contract operation as it lands. Ids are the contract's id_param.
  namespace :internal do
    namespace :v1 do
      resources :entries, only: %i[index show], constraints: { id: /[1-9][0-9]*/ }
    end
  end
end
