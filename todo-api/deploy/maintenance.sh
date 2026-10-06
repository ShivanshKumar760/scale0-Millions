#!/bin/bash
# Usage: deploy/maintenance.sh stop|start
set -euo pipefail
cd "$(dirname "$0")/.."
ACTION=${1:?usage: deploy/maintenance.sh stop|start}
for IP in $(terraform -chdir=infra output -json api_public_ips | jq -r '.[]'); do
  echo "-- $ACTION todo-api on $IP"
  ssh -o StrictHostKeyChecking=accept-new root@"$IP" "docker $ACTION todo-api"
done