# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session_or_guest_sandbox
    helper_method :authenticated?, :current_user, :current_studio_setting, :guest_sample_count
  end

  private

  def authenticated?
    current_user.present?
  end

  def current_user
    Current.user
  end

  def current_studio_setting
    @current_studio_setting ||= StudioSetting.for_context(
      user: current_user,
      guest_token: Current.guest_token
    )
  end

  def guest_sample_count
    return 0 if authenticated? || Current.guest_token.blank?

    UserSample.where(user_id: nil, guest_token: Current.guest_token).count
  end

  def resume_session_or_guest_sandbox
    if (session_record = find_session_by_cookie)
      Current.session = session_record
      Current.guest_token = nil
    else
      cookies.delete(:session_id) if cookies.signed[:session_id].present?
      Current.session = nil
      ensure_guest_sandbox_cookie!
    end
  end

  def find_session_by_cookie
    session_id = cookies.signed[:session_id]
    Session.includes(:user).find_by(id: session_id) if session_id.present?
  end

  def ensure_guest_sandbox_cookie!
    token = cookies.signed[:guest_token].presence
    if token.blank?
      token = SecureRandom.urlsafe_base64(24)
      cookies.signed.permanent[:guest_token] = {
        value: token,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?
      }
    end
    Current.guest_token = token
  end

  def start_new_session_for(user)
    prev_guest_token = cookies.signed[:guest_token].presence || Current.guest_token.presence
    return_to = session[:return_to_after_authenticating]
    Current.session&.destroy
    reset_session
    session[:return_to_after_authenticating] = return_to if return_to.present?
    claimed_samples = 0

    Session.transaction do
      session_record = user.sessions.create!(
        user_agent: request.user_agent,
        ip_address: request.remote_ip
      )
      Current.session = session_record
      Current.guest_token = nil
      cookies.signed.permanent[:session_id] = {
        value: session_record.id,
        httponly: true,
        same_site: :lax,
        secure: Rails.env.production?
      }
      claimed_samples = claim_guest_sandbox!(user, prev_guest_token)
    end

    cookies.delete(:guest_token)
    @current_studio_setting = nil
    claimed_samples
  end

  def claim_guest_sandbox!(user, guest_token)
    return 0 if guest_token.blank? || user.blank?

    claimed_count = UserSample.claim_guest!(guest_token: guest_token, user: user)
    StudioSetting.claim_guest!(guest_token: guest_token, user: user)
    claimed_count
  end

  def terminate_session
    Current.session&.destroy
    reset_session
    Current.session = nil
    cookies.delete(:session_id)
    @current_studio_setting = nil
  end

  def require_authentication
    return if authenticated?

    session[:return_to_after_authenticating] = request.fullpath if request.get? || request.head?
    redirect_to new_session_path, alert: "Please sign in to your studio account to continue."
  end

  def after_authentication_url
    return_to = session.delete(:return_to_after_authenticating)
    if return_to.is_a?(String) && return_to.start_with?("/") && !return_to.start_with?("//", "/\\")
      return_to
    else
      root_path
    end
  end

  def scoped_samples
    UserSample.for_owner(user: current_user, guest_token: Current.guest_token)
  end

  def assign_sample_ownership(sample)
    if current_user.present?
      sample.user = current_user
      sample.guest_token = nil
    else
      sample.guest_token ||= Current.guest_token
    end
    sample
  end
end
