# frozen_string_literal: true

class ApiTokensController < ApplicationController
  before_action :require_authentication

  rate_limit to: 10, within: 5.minutes, only: :create, with: -> {
    redirect_to setup_path(step: 4), alert: "Too many token requests. Try again shortly."
  }

  def create
    name = (params.dig(:api_token, :name) || params[:name]).to_s.strip
    if name.blank?
      redirect_to setup_path(step: 4), alert: "Please enter a name for your API token."
      return
    end

    record, plaintext = ApiToken.issue!(user: current_user, name: name)
    flash[:newly_created_api_token] = plaintext
    redirect_to setup_path(step: 4),
      notice: "API token \"#{record.name}\" created. Copy it now — this is the only time it will be shown."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to setup_path(step: 4), alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    token = current_user.api_tokens.find(params[:id])
    token.revoke!
    redirect_to setup_path(step: 4), notice: "API token \"#{token.name}\" revoked."
  end
end
