# Image Caching Server

A Phoenix-based image caching and scaling server that provides an API to scale images and caches both original and scaled versions. Optimizes images by converting them to WebP format (except for GIFs which remain in their original format).

## Features

- Image scaling via API
- Automatic WebP conversion for optimized file sizes
- LRU caching of both original and scaled images
- Configurable cache size and eviction policies
- Origin domain verification for security
- Persistent cache storage
- No database required

## Prerequisites

- Elixir 1.14 or later
- ImageMagick (for image processing)
- Docker (optional, for container deployment)

## API Usage

### Scale Image

```
GET /api/scale?url=<image_url>&width=<target_width>
```

Parameters:
- `url`: The URL of the image to scale (must be from an allowed domain)
- `width`: The target width in pixels (height will be scaled proportionally)

Example:
```
GET /api/scale?url=https://example.com/image.jpg&width=300
```

Response:
- Success: Returns the scaled image (WebP format for non-GIFs, original format for GIFs)
- Error: Returns a JSON error message with appropriate HTTP status code

## Configuration

The following environment variables can be used to configure the server:

- `PORT`: Server port (default: 4000)
- `CACHE_DIR`: Directory for cached images (default: "priv/cache")
- `MAX_CACHE_SIZE_MB`: Maximum cache size in megabytes (default: 1024)
- `ALLOWED_DOMAINS`: Comma-separated list of domains allowed to be source of requests
- `SECRET_KEY_BASE`: Phoenix secret key base
- `PHX_HOST`: Host name for production deployment

## Deployment

### Docker Deployment

1. Build the Docker image:
```bash
docker build -t image-caching-server .
```

2. Run the container:
```bash
docker run -d \
  -p 4000:4000 \
  -e ALLOWED_DOMAINS=domain1.com,domain2.com \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -v /path/to/cache:/var/cache/images \
  image-caching-server
```

The server will be available at `http://localhost:4000`.

Note: Replace `/path/to/cache` with a local directory path for persistent cache storage.

### Render.com Deployment

The service is configured for deployment on Render.com with the following features:
- Persistent disk for cache storage
- Automatic HTTPS
- Health checks
- Automatic restarts and recovery

Required environment variables for Render.com:
```
ALLOWED_DOMAINS=domain1.com,domain2.com
SECRET_KEY_BASE=(generate with: mix phx.gen.secret)
PHX_HOST=your-app-name.onrender.com
```

To deploy on Render.com:
1. Fork or clone this repository
2. Create a new Web Service on Render
3. Connect your repository
4. Set the required environment variables
5. Deploy

### Local Development

1. Install dependencies:
```bash
mix deps.get
```

2. Start the server:
```bash
mix phx.server
```

The server will be available at `http://localhost:4002`.

## Cache Behavior

- Images are cached both in original and scaled versions
- Non-GIF images are automatically converted to WebP format for better compression
- GIF images maintain their original format to preserve animation
- Cache uses LRU (Least Recently Used) eviction policy
- Cache is evicted when size exceeds 90% of maximum configured size
- Cache persists across server restarts

## Security

- Only allows image downloads from configured domains
- Requires Origin or Referer headers for API requests
- Validates URLs before processing
- Limits maximum cache size to prevent disk space issues

## Image Download Troubleshooting

The image caching server uses a robust download system to handle various image sources. We've optimized the download strategy after extensive testing with problematic URLs.

We've implemented the following improvements:

1. Used a dual-strategy approach with Req client as primary and curl-based fallback
2. Removed unnecessary HTTP client dependencies (HTTPoison)
3. Fixed TLS version atoms (changing :`tlsv1.2` to `:tlsv1_2`)
4. Simplified URL handling by using direct URLs without transformation
5. Added better error handling to prevent crashes during downloads

### Current Download Strategy

After systematic testing with various problematic URLs, we've implemented a reliable download strategy:

1. **Primary: Req HTTP Client**: A modern Elixir HTTP client with optimized TLS settings for maximum compatibility
2. **Fallback: System.cmd with curl**: When Req fails, the system falls back to curl which has proven to be the most reliable option

This dual-strategy approach provides both:
- Fast downloads with the native Elixir client for most URLs
- Maximum compatibility with difficult servers via curl fallback

### Testing the Download System

You can test the download functionality with problematic URLs using:

```bash
mix run test_downloader.exs
```

For a more comprehensive test across multiple HTTP clients:

```bash
mix run test_native_clients.exs
```

## Code Optimization

The server has been optimized in several ways:

1. Removed unnecessary UI-related dependencies (esbuild, tailwind, phoenix_html, etc.)
2. Fixed Logger.warn deprecation warnings by changing to Logger.warning
3. Ensured proper return values from functions to avoid pattern match errors
4. Removed unused URL transformation code
5. Simplified error handling and validation

## License

MIT 