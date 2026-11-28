# frozen_string_literal: true

class PasswordsController < ApplicationController
  rate_limit to: 5, within: 5.minutes, only: :create, with: -> {
    redirect_to new_password_path, alert: "Too many password reset requests. Try again in a few minutes."
  }

  before_action :set_user_by_token, only: %i[edit update]

  def new
  end

  def create
    email = extract_email
    if (user = User.find_by(email: email)) && user.password_digest.present?
      PasswordsMailer.reset(user).deliver_later
    end

    redirect_to new_session_path,
      notice: "Password reset instructions sent (if an account with that email address exists)."
  end

  def edit
  end

  def update
    @user.assign_attributes(password_params)
    if @user.save(context: :password_reset)
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset. Please sign in with your new password."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_user_by_token
    @token = params[:token]
    @user = User.find_by_token_for(:password_reset, @token)
    return if @user.present?

    redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
  end

  def extract_email
    raw = params.dig(:password, :email) || params.dig(:user, :email) || params[:email]
    raw.to_s.strip.downcase
  end

  def password_params
    if params[:user].respond_to?(:permit)
      params.require(:user).permit(:password, :password_confirmation)
    elsif params[:password_reset].respond_to?(:permit)
      params.require(:password_reset).permit(:password, :password_confirmation)
    else
      params.permit(:password, :password_confirmation)
    end
  end
end
