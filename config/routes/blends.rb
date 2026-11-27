# frozen_string_literal: true

resources :samples, only: [] do
  resource :glazecalc_push, only: [ :create ]
end

resources :blends, only: [ :index, :create ] do
  collection do
    get :export_glazecalc
    get :export_glaze_vault
  end
end
