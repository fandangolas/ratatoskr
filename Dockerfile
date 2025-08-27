# Build stage
FROM elixir:1.17.3-otp-27 AS builder

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV=prod

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config

# Install mix dependencies
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy application files
COPY lib lib
COPY priv priv

# Compile application
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libssl3 \
    libncurses6 \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Create app user
RUN groupadd -g 1000 ratatoskr && \
    useradd -u 1000 -g ratatoskr -m -s /bin/bash ratatoskr

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=ratatoskr:ratatoskr /app/_build/prod/rel/ratatoskr ./

# Set user
USER ratatoskr

# Expose gRPC port
EXPOSE 50051

# Set the entrypoint
CMD ["bin/ratatoskr", "start"]