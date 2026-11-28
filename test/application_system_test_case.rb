# frozen_string_literal: true

require "test_helper"
require "capybara"
require "capybara/selenium/driver"
require "capybara/selenium/driver_specializations/chrome_driver"

# Chrome 134+ rejects `origin: "*"` in CDP `Storage.clearDataForOrigin` during
# Capybara 3.40's `ChromeDriver#reset!`. Clear DOM storage before navigating to
# `about:blank` and use `Network.clearBrowserCookies` when `origin == "*"`.
module CapybaraChromeModernResetPatch
  private

  def uniform_storage_clear?
    false
  end

  def execute_cdp(cmd, params = {})
    if cmd == "Storage.clearDataForOrigin" && params[:origin] == "*"
      return super("Network.clearBrowserCookies")
    end

    super
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(CapybaraChromeModernResetPatch)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  CHROME_BINARIES = %w[google-chrome chrome chromium chromium-browser].freeze

  def self.chrome_available?
    return false if ENV["SYSTEM_TEST_DRIVER"] == "rack_test"
    return true if ENV["CHROME_BIN"].present? && File.executable?(ENV["CHROME_BIN"])

    CHROME_BINARIES.any? { |bin| system("which #{bin} >/dev/null 2>&1") }
  end

  if chrome_available?
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ] do |driver_option|
      driver_option.binary = ENV["CHROME_BIN"] if ENV["CHROME_BIN"].present?
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
