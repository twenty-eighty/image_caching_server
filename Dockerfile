FROM hexpm/elixir:1.14.5-erlang-25.3.2.3-debian-bullseye-20230227 as build

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
FROM debian:bullseye-slim

# Install runtime dependencies (already in build script, but needed for runtime)
RUN apt-get update -y && \
    apt-get install -y imagemagick file libstdc++6 openssl libncurses5 locales && \
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

# Run the Phoenix app
CMD ["bin/image_caching_server", "start"] 