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

## License

MIT 