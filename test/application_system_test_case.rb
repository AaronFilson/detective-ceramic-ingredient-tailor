# frozen_string_literal: true

require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  CHROME_BINARIES = %w[google-chrome chromium chromium-browser].freeze

  def self.chrome_available?
    return false if ENV["SYSTEM_TEST_DRIVER"] == "rack_test"

    CHROME_BINARIES.any? { |bin| system("which #{bin} >/dev/null 2>&1") }
  end

  if chrome_available?
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ] do |driver_option|
      driver_option.add_argument("--no-sandbox")
      driver_option.add_argument("--disable-dev-shm-usage")
    end
  else
    driven_by :rack_test
  end

  def js_driver?
    Capybara.current_driver != :rack_test
  end
end
