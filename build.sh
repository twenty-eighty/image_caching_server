#!/bin/bash
set -e  # Exit on any error

echo "Setting up environment..."
export MIX_ENV=prod
export ERL_AFLAGS="-kernel shell_history enabled"

echo "Installing system dependencies..."
apt-get update -y
apt-get install -y imagemagick file

echo "Installing Elixir tools..."
mix local.hex --force
mix local.rebar --force

echo "Getting and compiling dependencies..."
mix deps.get --only prod
mix deps.compile --all
mix compile

echo "Setting up cache directory..."
mkdir -p ${CACHE_DIR}
chmod 777 ${CACHE_DIR}

echo "Build completed successfully!" 