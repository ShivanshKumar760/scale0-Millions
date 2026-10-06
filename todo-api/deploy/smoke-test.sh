#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Target = the droplet load balancer by default; override with BASE_URL=http://<ip> (used in Part 2)
LB="${BASE_URL:-http://$(terraform -chdir=infra output -raw lb_ip)}"
EMAIL="smoke4$(date +%s)@example.com"
J='Content-Type: application/json'

echo "health:";  curl -s $LB/healthz; echo
echo "register:"; curl -s -X POST $LB/api/auth/register -H "$J" -d "{\"email\":\"$EMAIL\",\"password\":\"password123\"}"; echo
TOKEN=$(curl -s -X POST $LB/api/auth/login -H "$J" -d "{\"email\":\"$EMAIL\",\"password\":\"password123\"}" | jq -r .access_token)
echo "create:";  curl -s -X POST $LB/api/todos -H "Authorization: Bearer $TOKEN" -H "$J" -d '{"title":"hello 1M users"}'; echo
echo "list x3 (expect MISS then HIT):"
for i in 1 2 3; do curl -s -o /dev/null -D - $LB/api/todos -H "Authorization: Bearer $TOKEN" | grep -i -E '^(x-cache|x-served-by)' | tr '\r\n' '  ' || true; echo; done
echo "load balancing across servers:"
for i in $(seq 1 12); do curl -s -o /dev/null -D - $LB/healthz | grep -i '^x-served-by' | tr -d '\r' || true; done | sort | uniq -c