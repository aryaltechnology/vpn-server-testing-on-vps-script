#!/bin/bash
echo "🔨 Building..."
docker build -t vpn-tester-local .

if [ $? -eq 0 ]; then
  echo "🚀 Running..."
  docker run -it --rm \
    --cap-add=NET_ADMIN \
    --device /dev/net/tun \
    -p 8080:8080 \
    vpn-tester-local
else
  echo "❌ Build Failed."
fi