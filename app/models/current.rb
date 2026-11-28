# frozen_string_literal: true

class Current < ActiveSupport::CurrentAttributes
  attribute :session, :guest_token

  delegate :user, to: :session, allow_nil: true
end
