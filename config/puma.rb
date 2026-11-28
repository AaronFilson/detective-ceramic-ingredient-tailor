# frozen_string_literal: true

require "active_model"

# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

threads_count = ENV.fetch("RAILS_MAX_THREADS", 3).to_i
threads threads_count, threads_count

# Default to single-process mode (WEB_CONCURRENCY=0) to save ~120 MB RAM on t4g.small;
# enable clustered workers only when WEB_CONCURRENCY > 1.
web_concurrency = ENV.fetch("WEB_CONCURRENCY", 0).to_i
if web_concurrency > 1
  workers web_concurrency
else
  workers 0
end

# Specifies the `port` that Puma will listen on to receive requests; default is 3000.
port ENV.fetch("PORT", 3000)

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor in-process inside Puma for single-server deployments.
if ActiveModel::Type::Boolean.new.cast(ENV["SOLID_QUEUE_IN_PUMA"])
  plugin :solid_queue
  solid_queue_mode :async
end

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
