FROM hexpm/elixir:1.14.5-erlang-25.3.2.3-debian-bullseye-20230227 as build

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install ImageMagick
RUN apt-get update -y && apt-get install -y imagemagick \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Prepare build dir
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

# Build assets
COPY priv priv
COPY lib lib
RUN MIX_ENV=prod mix compile

# Build the release
RUN MIX_ENV=prod mix release

# Start a new build stage
FROM debian:bullseye-slim

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y imagemagick libstdc++6 openssl libncurses5 locales file \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app

# Copy the release from the build stage
COPY --from=build /app/_build/prod/rel/image_caching_server ./

# Create cache directory
RUN mkdir -p /cache

# Set environment variables
ENV MIX_ENV=prod
ENV PORT=4000
ENV CACHE_DIR=/cache

# Create volume for persistent cache
VOLUME /cache

# Run the Phoenix app
CMD ["bin/image_caching_server", "start"] 