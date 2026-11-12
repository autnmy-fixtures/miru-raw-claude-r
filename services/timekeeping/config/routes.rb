# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness for the local demo runtime (§11.2): 200 once the app has booted.
  get "up" => "rails/health#show", as: :rails_health_check
end
