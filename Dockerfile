FROM ruby:3.3-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      libpq-dev \
      libgeos-dev \
      libproj-dev \
      postgresql-client \
      git \
      curl \
      libyaml-dev \
      pkg-config \
      libffi-dev && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

WORKDIR /rails

RUN gem install bundler && gem install rails -v '~> 8.1'

COPY Gemfile Gemfile.lock ./
RUN bundle install

EXPOSE 3000

CMD ["bash", "-c", "rm -f tmp/pids/server.pid && bundle exec rails db:prepare tailwindcss:build && bundle exec rails server -b 0.0.0.0 -p 3000"]
