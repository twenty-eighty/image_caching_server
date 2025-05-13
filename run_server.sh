#!/bin/bash

# Default values
DEFAULT_PORT=4000
DEFAULT_CACHE_DIR="priv/cache"
DEFAULT_MAX_CACHE_SIZE_MB=1024
DEFAULT_ALLOWED_DOMAINS="localhost,127.0.0.1"

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -p, --port PORT                Server port (default: $DEFAULT_PORT)"
    echo "  -c, --cache-dir DIR            Cache directory (default: $DEFAULT_CACHE_DIR)"
    echo "  -s, --max-cache-size SIZE      Max cache size in MB (default: $DEFAULT_MAX_CACHE_SIZE_MB)"
    echo "  -d, --allowed-domains DOMAINS  Comma-separated list of allowed domains (default: $DEFAULT_ALLOWED_DOMAINS)"
    echo "  -b, --bind-address ADDR        Address to bind to (default: 127.0.0.1)"
    echo "  -e, --env ENVIRONMENT          Run environment [dev|prod] (default: dev)"
    echo "  -l, --log-level LEVEL          Log level [debug|info|warn|error] (default: info)"
    echo "  --enable-cors                  Enable CORS support"
    echo "  -h, --help                     Show this help message"
    echo
    echo "Example:"
    echo "  $0 --port 4000 --cache-dir /cache --max-cache-size 2048 --allowed-domains 'example.com,*.trusted.com'"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -c|--cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        -s|--max-cache-size)
            MAX_CACHE_SIZE_MB="$2"
            shift 2
            ;;
        -d|--allowed-domains)
            ALLOWED_DOMAINS="$2"
            shift 2
            ;;
        -b|--bind-address)
            BIND_ADDRESS="$2"
            shift 2
            ;;
        -e|--env)
            MIX_ENV="$2"
            shift 2
            ;;
        -l|--log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --enable-cors)
            ENABLE_CORS=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Set defaults if not provided
PORT=${PORT:-$DEFAULT_PORT}
CACHE_DIR=${CACHE_DIR:-$DEFAULT_CACHE_DIR}
MAX_CACHE_SIZE_MB=${MAX_CACHE_SIZE_MB:-$DEFAULT_MAX_CACHE_SIZE_MB}
ALLOWED_DOMAINS=${ALLOWED_DOMAINS:-$DEFAULT_ALLOWED_DOMAINS}
BIND_ADDRESS=${BIND_ADDRESS:-"127.0.0.1"}
MIX_ENV=${MIX_ENV:-"dev"}
LOG_LEVEL=${LOG_LEVEL:-"info"}
ENABLE_CORS=${ENABLE_CORS:-false}

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR"

# Export all environment variables
export PORT
export CACHE_DIR
export MAX_CACHE_SIZE_MB
export ALLOWED_DOMAINS
export MIX_ENV
export ENABLE_CORS

# Set Phoenix endpoint configuration
export PHX_SERVER=true
export PHX_HOST="localhost"

# Set logging configuration
export LOGGER_LEVEL="$LOG_LEVEL"

# Print configuration
echo "Starting Image Caching Server with configuration:"
echo "----------------------------------------"
echo "Port:            $PORT"
echo "Cache Directory: $CACHE_DIR"
echo "Max Cache Size:  ${MAX_CACHE_SIZE_MB}MB"
echo "Allowed Domains: $ALLOWED_DOMAINS"
echo "Bind Address:    $BIND_ADDRESS"
echo "Environment:     $MIX_ENV"
echo "Log Level:       $LOG_LEVEL"
echo "CORS Enabled:    $ENABLE_CORS"
echo "----------------------------------------"

# Check if we need to compile
if [ ! -d "_build/${MIX_ENV}" ]; then
    echo "Compiling application..."
    mix deps.get
    mix compile
fi

# Start the server
if [ "$MIX_ENV" = "prod" ]; then
    echo "Starting server in production mode..."
    mix phx.server
else
    echo "Starting server in development mode..."
    mix phx.server
fi 