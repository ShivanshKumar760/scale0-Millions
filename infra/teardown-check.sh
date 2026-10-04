#!/bin/bash
for r in "compute droplet" "compute load-balancer" "compute firewall" "kubernetes cluster" \
         "databases" "compute volume" "compute snapshot" "compute reserved-ip" \
         "compute domain" "compute certificate" "compute tag" "compute ssh-key" "vpcs"; do
  echo "== doctl $r list"
  doctl $r list 2>&1 | head -20
done
echo "== registry"; doctl registry get 2>&1 | head -5
