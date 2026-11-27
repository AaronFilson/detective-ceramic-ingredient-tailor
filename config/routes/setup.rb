# frozen_string_literal: true

resource :setup, only: %i[show update], controller: "setup_wizard" do
  post :skip
  post :reset
end
