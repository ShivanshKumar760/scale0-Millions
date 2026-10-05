# #!/bin/bash
# # Usage:  deploy/deploy.sh [image-tag]      (default tag = current git commit)
# # Rollback = run it again with an older tag.
# set -euo pipefail
# cd "$(dirname "$0")/.."

# TAG=${1:-$(git rev-parse --short HEAD)}
# API_WORKERS=${API_WORKERS:-5}                 # gunicorn workers per droplet (2 x vCPUs + 1)
# OUT=$(terraform -chdir=infra output -json)
# get() { echo "$OUT" | jq -r ".$1.value"; }

# IMAGE="$(get registry_endpoint)/todo-api:$TAG"

# echo "== 1/3 build and push $IMAGE"
# doctl registry login --expiry-seconds 3600
# docker build --platform linux/amd64 -t "$IMAGE" app
# docker push "$IMAGE"

# # Connection strings: every host below is a PRIVATE VPC IP produced by Terraform
# DB_PASS=$(get app_db_password)
# REDIS_PASS=$(get redis_password)
# JWT=$(get jwt_secret)
# PRIMARY=$(get pg_primary_private_ip)
# REDIS=$(get redis_private_ip)
# READ_URLS=$(echo "$OUT" | jq -r --arg p "$DB_PASS" \
#   '[.pg_replica_private_ips.value[] | "postgresql://todo:\($p)@\(.):5432/todo"] | join(",")')
# API_IPS=$(echo "$OUT" | jq -r '.api_public_ips.value[]')

# echo "== 2/3 rolling deploy"
# for IP in $API_IPS; do
#   echo "-- $IP"
#   ssh -o StrictHostKeyChecking=accept-new root@"$IP" "cloud-init status --wait >/dev/null 2>&1 || true; mkdir -p /opt/todo"

#   # (Re)write this server's environment file
#   ssh root@"$IP" "cat > /opt/todo/app.env && chmod 600 /opt/todo/app.env" <<EOF
# JWT_SECRET_KEY=$JWT
# DATABASE_URL=postgresql://todo:$DB_PASS@$PRIMARY:5432/todo
# READ_DATABASE_URL=$READ_URLS
# REDIS_URL=redis://:$REDIS_PASS@$REDIS:6379/0
# WEB_CONCURRENCY=$API_WORKERS
# EOF

#   # Pull the image, replace the running container
#   ssh root@"$IP" "docker pull $IMAGE \
#     && (docker rm -f todo-api >/dev/null 2>&1 || true) \
#     && docker run -d --name todo-api --restart unless-stopped -p 80:8000 \
#          --env-file /opt/todo/app.env --log-opt max-size=50m --log-opt max-file=3 $IMAGE"

#   # Wait until this server answers, then give the load balancer time to see it healthy
#   for i in $(seq 1 30); do
#     ssh root@"$IP" "curl -fs http://127.0.0.1/healthz" >/dev/null 2>&1 && break
#     sleep 2
#   done
#   sleep 25
# done

# echo "== 3/3 done: $IMAGE is live on all API servers"




#!/bin/bash
# Usage:  [MODE=sharded] deploy/deploy.sh [image-tag]     (MODE defaults to "single")
# Rollback = run it again with an older tag.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${MODE:-single}
TAG=${1:-$(git rev-parse --short HEAD)}
API_WORKERS=${API_WORKERS:-5}
OUT=$(terraform -chdir=infra output -json)
get() { echo "$OUT" | jq -r ".$1.value"; }

IMAGE="$(get registry_endpoint)/todo-api:$TAG"

echo "== 1/3 build and push $IMAGE  (mode: $MODE)"
doctl registry login --expiry-seconds 3600
docker build --platform linux/amd64 -t "$IMAGE" app
docker push "$IMAGE"

DB_PASS=$(get app_db_password)
REDIS_PASS=$(get redis_password)
JWT=$(get jwt_secret)
REDIS=$(get redis_private_ip)

if [ "$MODE" = "sharded" ]; then
  SHARDS=$(get shard_count)
  if [ "$SHARDS" -lt 2 ]; then
    echo "MODE=sharded needs shard_count >= 2 in infra/terraform.tfvars" >&2
    exit 1
  fi

  # Safety guard: the shard count must never change once users exist.
  GUARD=deploy/SHARD_COUNT
  if [ -f "$GUARD" ] && [ "$(cat "$GUARD")" != "$SHARDS" ] && [ "${FORCE_RESHARD:-0}" != "1" ]; then
    echo "STOP: shard_count is $SHARDS but this platform was deployed with $(cat "$GUARD") shards." >&2
    echo "Changing it re-routes users to the wrong shards. Migrate the data first, then run with FORCE_RESHARD=1." >&2
    exit 1
  fi
  echo "$SHARDS" > "$GUARD"                       # commit this file to git

  # Element i of shard_private_ips is shard i: every host is a PRIVATE VPC IP produced by Terraform
  SHARD_URLS=$(echo "$OUT" | jq -r --arg p "$DB_PASS" \
    '[.shard_private_ips.value | to_entries[] | "postgresql://todo:\($p)@\(.value):5432/todo_shard\(.key)"] | join(",")')
  INDEX_URL="postgresql://todo:$DB_PASS@$(get shard_index_private_ip):5432/todo_index"
  DB_ENV="SHARD_URLS=$SHARD_URLS
SHARD_INDEX_URL=$INDEX_URL"
else
  PRIMARY=$(get pg_primary_private_ip)
  if [ "$PRIMARY" = "null" ]; then
    echo "There is no single primary (enable_single_db = false). Use: MODE=sharded deploy/deploy.sh" >&2
    exit 1
  fi
  READ_URLS=$(echo "$OUT" | jq -r --arg p "$DB_PASS" \
    '[.pg_replica_private_ips.value[] | "postgresql://todo:\($p)@\(.):5432/todo"] | join(",")')
  DB_ENV="DATABASE_URL=postgresql://todo:$DB_PASS@$PRIMARY:5432/todo
READ_DATABASE_URL=$READ_URLS"
fi

API_IPS=$(echo "$OUT" | jq -r '.api_public_ips.value[]')

echo "== 2/3 rolling deploy"
for IP in $API_IPS; do
  echo "-- $IP"
  ssh -o StrictHostKeyChecking=accept-new root@"$IP" "cloud-init status --wait >/dev/null 2>&1 || true; mkdir -p /opt/todo"

  ssh root@"$IP" "cat > /opt/todo/app.env && chmod 600 /opt/todo/app.env" <<EOF
JWT_SECRET_KEY=$JWT
$DB_ENV
REDIS_URL=redis://:$REDIS_PASS@$REDIS:6379/0
WEB_CONCURRENCY=$API_WORKERS
EOF

  ssh root@"$IP" "docker pull $IMAGE \
    && (docker rm -f todo-api >/dev/null 2>&1 || true) \
    && docker run -d --name todo-api --restart unless-stopped -p 80:8000 \
         --env-file /opt/todo/app.env --log-opt max-size=50m --log-opt max-file=3 $IMAGE"

  for i in $(seq 1 30); do
    ssh root@"$IP" "curl -fs http://127.0.0.1/healthz" >/dev/null 2>&1 && break
    sleep 2
  done
  sleep 25
done

echo "== 3/3 done: $IMAGE is live on all API servers ($MODE mode)"