# syntax=docker/dockerfile:1
# check=error=true

# Timekeeping's own image (docs/architecture/timekeeping-soa.md §11.1, §11.2,
# §14 "Deployment and runtime"). It holds this service and the one shared
# library it reads, packages/timekeeping_reservations, and nothing of the
# existing application, so either image is rebuilt and restarted without the
# other (§13 item 4).
#
# Build it from the repository root, because the shared library lives outside
# this directory:
#
#   docker build -f services/timekeeping/Dockerfile -t timekeeping .
#
# Dockerfile.dockerignore, next to this file, keeps everything else out of the
# build context. Configuration comes from the container's environment, never
# from the image (§11.2): DATABASE_URL, SECRET_KEY_BASE and
# TIMEKEEPING_TOKEN_KEY (credentials), EXISTING_APP_URL (plain) and PORT (3100
# by default).
#
# The same image runs both of Timekeeping's processes (§11.1):
#
#   web:    the default command, Puma on PORT
#   worker: bin/rails solid_queue:start, the relay's dedicated worker on the
#           timekeeping_relay queue

# Make sure RUBY_VERSION matches services/timekeeping/.ruby-version.
ARG RUBY_VERSION=4.0.1
FROM ruby:$RUBY_VERSION-slim AS base

# The service sits where it sits in the repository, so its initializer finds
# the shared library at ../../packages, as it does in a checkout.
WORKDIR /app/services/timekeeping

# libpq for the pg gem, curl for the container's health check.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libpq5 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    RAILS_ENV="production"


# Throw-away stage that compiles the gems.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY services/timekeeping/Gemfile services/timekeeping/Gemfile.lock ./
RUN gem install -N bundler -v "$(tail -n 1 Gemfile.lock | tr -d ' ')" && \
    bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY packages/timekeeping_reservations/ /app/packages/timekeeping_reservations/
COPY services/timekeeping/ ./

# Fails the build if the application does not boot in production: eager
# loading reads every class, the shared library and the contracts. The boot
# needs a secret_key_base; the build has none, so it uses Rails' throwaway one.
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails runner 'TimekeepingReservations::TABLE.fetch([:save, :draft, :added]); Rails.configuration.x.timekeeping.contracts_dir.join("entry_api.json").read'


# Final image.
FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /app /app

# Run as a non-root user that owns only what the process writes.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails log tmp
USER 1000:1000

# The revision the image was built from, so a restart records which version
# of Timekeeping is running (§11.2, §13 item 4).
ARG REVISION=unknown
LABEL org.opencontainers.image.title="timekeeping" \
      org.opencontainers.image.source="services/timekeeping" \
      org.opencontainers.image.revision="${REVISION}"
ENV TIMEKEEPING_REVISION="${REVISION}"

ENV PORT=3100
EXPOSE 3100
HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/up" || exit 1

ENTRYPOINT ["/app/services/timekeeping/bin/docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
