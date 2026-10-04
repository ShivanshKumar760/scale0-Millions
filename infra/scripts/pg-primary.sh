#!/bin/bash
set -euo pipefail
source /opt/bootstrap/env

# This droplet's own PRIVATE IP, from DigitalOcean's metadata service (works only from inside a droplet)
MY_IP=$(curl -s http://169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)

mkdir -p /opt/pg/data /opt/pg/initdb.d /var/backups/postgres

# cloud-init writes files as root with mode 0700, but the Postgres container runs the init script and
# reads the schema as the unprivileged "postgres" user. Copy them and make them readable, otherwise
# first-boot initialisation fails with "Permission denied".
cp /opt/bootstrap/pg-init.sh /opt/pg/initdb.d/01-init.sh
cp /opt/bootstrap/schema.sql /opt/pg/schema.sql
chmod 755 /opt/pg/initdb.d/01-init.sh
chmod 644 /opt/pg/schema.sql

# --network host: Postgres binds directly to the droplet's private IP (and localhost), never the public one
docker run -d --name pg --restart unless-stopped --network host --shm-size=1g \
  -e POSTGRES_PASSWORD="$PG_SUPERUSER_PASSWORD" \
  -e POSTGRES_DB="$APP_DB" \
  -e APP_DB_PASSWORD="$APP_DB_PASSWORD" \
  -e REPL_PASSWORD="$REPL_PASSWORD" \
  -e VPC_CIDR="$VPC_CIDR" \
  -v /opt/pg/data:/var/lib/postgresql/data \
  -v /opt/pg/initdb.d:/docker-entrypoint-initdb.d:ro \
  -v /opt/pg/schema.sql:/schema.sql:ro \
  postgres:16 \
  -c listen_addresses="127.0.0.1,$MY_IP" \
  -c wal_level=replica -c max_wal_senders=10 -c wal_keep_size=2GB \
  -c max_connections=300 -c hot_standby=on \
  -c shared_buffers="$((MEM_MB / 4))MB" -c effective_cache_size="$((MEM_MB * 3 / 4))MB"

# Nightly logical backup at 02:00, keep 7 days
cat > /usr/local/bin/pg-backup.sh <<'EOF'
#!/bin/bash
set -euo pipefail
docker exec pg pg_dump -U postgres -Fc todo > /var/backups/postgres/todo-$(date +%F).dump
find /var/backups/postgres -name 'todo-*.dump' -mtime +7 -delete
EOF
chmod +x /usr/local/bin/pg-backup.sh
echo "0 2 * * * root /usr/local/bin/pg-backup.sh" > /etc/cron.d/pg-backup