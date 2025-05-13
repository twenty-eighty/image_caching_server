#!/bin/bash
set -e  # Exit on any error

echo "Setting up environment..."
export MIX_ENV=prod
export ERL_AFLAGS="-kernel shell_history enabled"

echo "Installing Elixir tools..."
mix local.hex --force
mix local.rebar --force

echo "Getting and compiling dependencies..."
mix deps.get --only prod
mix deps.compile --all
mix compile

echo "Build completed successfully!"