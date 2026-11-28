require "active_support/core_ext/integer/time"
require "uri"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Store uploaded files on local disk by default, or AWS S3 when ACTIVE_STORAGE_SERVICE=amazon.
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local").to_sym

  # Process EXIF-stripped display variants via libvips for low memory usage.
  config.active_storage.variant_processor = :vips

  # Assume all access to the app is happening through a SSL-terminating reverse proxy (host Nginx + kamal-proxy).
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint (required for kamal-proxy healthchecks).
  config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  # Uses the single primary PostGIS database (solid_queue_* tables live in db/migrate).
  config.active_job.queue_adapter = :solid_queue

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST", "dci-tailor.glazecalcapp.com"),
    protocol: "https"
  }

  # Configure outgoing SMTP delivery when SMTP_URL is provided (e.g. AWS SES in us-west-2).
  if ENV["SMTP_URL"].present?
    smtp_uri = URI.parse(ENV["SMTP_URL"])
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.perform_deliveries = true
    config.action_mailer.raise_delivery_errors = true
    config.action_mailer.smtp_settings = {
      address: smtp_uri.host,
      port: smtp_uri.port || 587,
      user_name: smtp_uri.user ? URI.decode_www_form_component(smtp_uri.user) : nil,
      password: smtp_uri.password ? URI.decode_www_form_component(smtp_uri.password) : nil,
      authentication: :plain,
      enable_starttls_auto: smtp_uri.scheme != "smtps",
      tls: smtp_uri.scheme == "smtps"
    }.compact
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection when APP_HOST is configured while exempting /up healthchecks.
  if ENV["APP_HOST"].present?
    config.hosts = [
      ENV["APP_HOST"],
      "127.0.0.1",
      "localhost"
    ]
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end
end
