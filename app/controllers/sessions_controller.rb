# frozen_string_literal: true

class SessionsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
    redirect_to new_session_path, alert: "Too many sign-in attempts. Try again in a few minutes."
  }

  def new
  end

  def create
    creds = session_params
    user = User.find_by(email: creds[:email].to_s.strip.downcase)

    if user&.password_digest.present? && user.authenticate(creds[:password].to_s)
      claimed = start_new_session_for(user)
      notice = if claimed.positive?
        "Welcome! Claimed #{claimed} guest studio #{'sample'.pluralize(claimed)} into your account."
      else
        "Signed in as #{user.name.presence || user.email}."
      end
      redirect_to after_authentication_url, notice: notice
    else
      flash.now[:alert] = "Invalid email address or password."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    terminate_session
    redirect_to root_path, notice: "Signed out. You are now in a fresh Guest Sandbox.", status: :see_other
  end

  private

  def session_params
    if params[:session].respond_to?(:permit)
      params.require(:session).permit(:email, :password)
    elsif params[:user].respond_to?(:permit)
      params.require(:user).permit(:email, :password)
    else
      params.permit(:email, :password)
    end
  end
end
