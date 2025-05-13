# Image Caching Server

A Phoenix-based image caching and scaling server that provides an API to scale images and caches both original and scaled versions.

## Features

- Image scaling via API
- LRU caching of both original and scaled images
- Docker containerization
- No database required

## Prerequisites

- Docker
- ImageMagick (for local development)

## API Usage

### Scale Image

```
GET /api/scale?url=<image_url>&size=<target_size>
```

Parameters:
- `url`: The URL of the image to scale
- `size`: The target size in pixels (width and height will be equal)

Example:
```
GET /api/scale?url=https://example.com/image.jpg&size=300
```

## Running with Docker

1. Build the Docker image:
```bash
docker build -t image-caching-server .
```

2. Run the container:
```bash
docker run -p 4000:4000 image-caching-server
```

The server will be available at `http://localhost:4000`.

## Local Development

1. Install dependencies:
```bash
mix deps.get
```

2. Start the server:
```bash
mix phx.server
```

## Configuration

The cache size is configured in `lib/image_caching_server/image_cache.ex`. The default is set to 100MB.

## License

MIT 