FROM elixir:1.20-slim as build

# Ensure certificates and git are available during build to avoid TLS issues
RUN apt-get update -y && \
    apt-get install -y ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

# Copy build script and make it executable
COPY build.sh /app/build.sh
RUN chmod +x /app/build.sh

# Set build environment variables
ENV MIX_ENV=prod
ENV CACHE_DIR=/cache

# Run build script
WORKDIR /app
COPY . .
RUN ./build.sh

# Start a new build stage
FROM debian:bookworm-slim

# Install runtime dependencies (already in build script, but needed for runtime)
RUN apt-get update -y && \
    apt-get install -y imagemagick file libstdc++6 openssl libncurses5 locales curl ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

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
VOLUME /cache

# Set environment variables
ENV MIX_ENV=prod
ENV PORT=4000
ENV CACHE_DIR=/cache
ENV PHX_SERVER=true

# Run the Phoenix app
CMD ["bin/image_caching_server", "start"]