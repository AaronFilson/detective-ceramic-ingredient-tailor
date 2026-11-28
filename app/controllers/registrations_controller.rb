# frozen_string_literal: true

class RegistrationsController < ApplicationController
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> {
    redirect_to new_registration_path, alert: "Too many sign-up attempts. Try again in a few minutes."
  }

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)

    if @user.save(context: :registration)
      claimed = start_new_session_for(@user)
      notice = if claimed.positive?
        "Welcome! Claimed #{claimed} guest studio #{'sample'.pluralize(claimed)} into your account."
      else
        "Welcome to DCI Tailor! Your studio account is ready."
      end
      redirect_to after_authentication_url, notice: notice
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    source = if params[:user].respond_to?(:permit)
      params.require(:user)
    elsif params[:registration].respond_to?(:permit)
      params.require(:registration)
    else
      params
    end
    source.permit(:name, :email, :password, :password_confirmation)
  end
end
