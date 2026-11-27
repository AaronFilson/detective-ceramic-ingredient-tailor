# frozen_string_literal: true

resources :samples, only: [] do
  resources :lab_assays, only: [ :create, :destroy ]
end
