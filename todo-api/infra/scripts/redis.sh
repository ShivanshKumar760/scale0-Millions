#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env          # provides REDIS_PASSWORD
MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)

# Cache semantics: bounded memory, evict least-recently-used keys, no disk persistence
docker run -d --name redis --restart unless-stopped --network host redis:7-alpine \
  redis-server --bind 127.0.0.1 "$MY_IP" --requirepass "$REDIS_PASSWORD" \
  --maxmemory 1gb --maxmemory-policy allkeys-lru --save "" --appendonly no