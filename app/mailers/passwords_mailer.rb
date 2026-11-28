# frozen_string_literal: true

class PasswordsMailer < ApplicationMailer
  def reset(user)
    @user = user
    @reset_token = user.generate_token_for(:password_reset)
    mail subject: "Reset your DCI Tailor studio password", to: user.email
  end
end
