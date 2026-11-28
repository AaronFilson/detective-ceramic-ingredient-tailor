# syntax=docker/dockerfile:1

ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim-bookworm AS base

WORKDIR /rails

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime-only shared libraries for PostGIS/RGeo, libvips variants, and jemalloc.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates \
      curl \
      libgeos-c1v5 \
      libjemalloc2 \
      libpq5 \
      libproj25 \
      libvips42 \
      postgresql-client && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Local development stage used by `docker compose up` (compose.yml target: development).
FROM base AS development

ENV BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libffi-dev \
      libgeos-dev \
      libpq-dev \
      libproj-dev \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY Gemfile Gemfile.lock ./
RUN bundle install

EXPOSE 3000

CMD ["bash", "-c", "rm -f tmp/pids/server.pid && bundle exec rails db:prepare tailwindcss:build && bundle exec rails server -b 0.0.0.0 -p 3000"]

# Throw-away build stage to reduce size of final production image (~380 MB vs ~1.4 GB).
FROM base AS build

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libffi-dev \
      libgeos-dev \
      libpq-dev \
      libproj-dev \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

RUN bundle exec bootsnap precompile app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails tailwindcss:build assets:precompile

# Final production stage (default target for Kamal / CI builds).
FROM base AS production

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    MALLOC_ARENA_MAX="2"

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build --chown=rails:rails /rails /rails

RUN mkdir -p /rails/log /rails/storage /rails/tmp/pids && \
    chown -R rails:rails /rails/log /rails/storage /rails/tmp

USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
