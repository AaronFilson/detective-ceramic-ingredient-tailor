# frozen_string_literal: true

resource :session, only: %i[new create destroy]
resource :registration, only: %i[new create]
resources :passwords, param: :token, only: %i[new create edit update]
resources :api_tokens, only: %i[create destroy]
