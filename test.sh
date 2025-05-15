#!/bin/bash

curl -v -H "Origin: http://localhost"  "http://localhost:4002/api/scale?url=https://picsum.photos/seed/The%20Business%20School%20and%20Bitcoin/800/400&width=100" --output /tmp/scaled_image.webp

curl -v -H "Origin: http://localhost"  "http://localhost:4002/api/scale?url=https://m.primal.net/IeiY.jpg&width=100" --output /tmp/scaled_image.webp

curl -v -H "Origin: http://localhost"  "http://localhost:4002/api/scale?url=https://cdn.nostr.build/i/p/fb4f2c4d4cf0255f39fb5ee98d5d14990e83804a44750b86e1e164a38934decc.jpg&width=100" --output /tmp/scaled_image.webp

curl -v -H "Origin: http://localhost"  "http://localhost:4002/api/scale?url=https://m.primal.net/NMdI.jpg&width=100" --output /tmp/scaled_image.webp

curl -v -L -H "Origin: http://localhost" "http://localhost:4002/api/scale?url=https://m.primal.net/LKte.jpg&width=102" --output /tmp/scaled_image.webp

curl -v -H "Origin: http://localhost"  "http://localhost:4002/api/scale?url=https://imgproxy.f7z.io/x_gXik-JZQ7U2VoQpIXhicgj5X27mTrdxHziH6GZImw/w:2400/aHR0cHM6Ly9ibG9zc29tLnByaW1hbC5uZXQvZTZlNjcxOWJhODQwOGJjMjJkMzNmNDgzNDgyOWYzYzU2NGE3MjJlNjMwMWI2YWI3ZDNlMDRkNTZlMmZlMTQ2MC5qcGc&width=300" --output scaled_image.webp


