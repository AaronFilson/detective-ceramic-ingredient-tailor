# frozen_string_literal: true

resources :mineral_occurrences, only: [ :index ] do
  collection do
    post :refresh
  end
end
