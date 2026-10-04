#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env          # provides PRIMARY_IP (the primary's private IP), REPL_PASSWORD

MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
mkdir -p /opt/pg/data

# The primary boots at the same time as us: wait until it accepts connections
until docker run --rm --network host postgres:16 pg_isready -h "$PRIMARY_IP" -p 5432 -q; do
  echo "waiting for primary at $PRIMARY_IP ..."; sleep 5
done

# Clone the primary's data directory (first boot only). -R writes standby.signal + connection info.
if [ -z "$(ls -A /opt/pg/data)" ]; then
  docker run --rm --network host -e PGPASSWORD="$REPL_PASSWORD" \
    -v /opt/pg/data:/var/lib/postgresql/data postgres:16 \
    bash -c "pg_basebackup -h $PRIMARY_IP -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R \
             && chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data"
fi

# Same server settings as the primary (a standby may not have LOWER values than its primary)
docker run -d --name pg --restart unless-stopped --network host --shm-size=1g \
  -v /opt/pg/data:/var/lib/postgresql/data \
  postgres:16 \
  -c listen_addresses="127.0.0.1,$MY_IP" \
  -c wal_level=replica -c max_wal_senders=10 -c wal_keep_size=2GB \
  -c max_connections=300 -c hot_standby=on \
  -c shared_buffers="$((MEM_MB / 4))MB" -c effective_cache_size="$((MEM_MB * 3 / 4))MB"