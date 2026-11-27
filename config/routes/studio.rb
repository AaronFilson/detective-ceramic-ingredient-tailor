# frozen_string_literal: true

root "samples#index"

resources :samples, only: %i[index show new create update destroy] do
  collection do
    get :geologic_lookup
  end

  resources :field_observations, only: %i[create update]
end
