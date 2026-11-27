# frozen_string_literal: true

get "/samples/:id/export/glazecalc", to: "sample_exports#glazecalc", as: :sample_glazecalc_export
get "/samples/:id/export/glaze_vault", to: "sample_exports#glaze_vault", as: :sample_glaze_vault_export

namespace :api, defaults: { format: :json } do
  namespace :v1 do
    resources :materials, only: %i[index show]
  end
end
