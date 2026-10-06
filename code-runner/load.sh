#!/usr/bin/env bash
# load.sh - dependency-free load tester: only curl, xargs, sort, awk (built in on Linux and macOS).
# usage: ./load.sh URL [TOTAL=200] [CONCURRENCY=10] ['JSON body'] ['Header: value']
#   GET  : ./load.sh http://1.2.3.4/ 500 20
#   POST : ./load.sh http://1.2.3.4/execute 1000 50 '{"code":"print(1)"}' "X-API-Key: $API_KEY"
set -uo pipefail
URL=${1:?usage: ./load.sh URL [TOTAL] [CONCURRENCY] ['JSON body'] ['Header: value']}
TOTAL=${2:-200}
CONC=${3:-10}
export URL BODY="${4:-}" HDR="${5:-}"

one() {                      # one request -> prints "<http_code> <seconds>"; code 000 = no HTTP response
  local args=(-s -o /dev/null -m 30 -w "%{http_code} %{time_total}\n")
  [ -n "$BODY" ] && args+=(-X POST -H "Content-Type: application/json" -d "$BODY")
  [ -n "$HDR" ]  && args+=(-H "$HDR")
  curl "${args[@]}" "$URL" || true     # on failure curl still prints "000 <time>"
}
export -f one

OUT=$(mktemp)
SECONDS=0
seq 1 "$TOTAL" | xargs -P "$CONC" -I{} bash -c one > "$OUT"
ELAPSED=$SECONDS

echo "== status codes (count, code) =="
awk '{print $1}' "$OUT" | sort | uniq -c | sort -rn

echo "== latency =="
sort -k2 -n "$OUT" | awk -v el="$ELAPSED" '
  function pct(p,  i) { i = int(NR*p); if (i < NR*p) i++; if (i < 1) i = 1; return a[i] }
  { a[NR] = $2; s += $2 }
  END {
    if (el < 1) el = 1
    printf "requests=%d elapsed=%ds rps=%.1f avg=%.3fs p50=%.3fs p95=%.3fs p99=%.3fs max=%.3fs\n",
           NR, el, NR/el, s/NR, pct(.50), pct(.95), pct(.99), a[NR]
  }'
rm -f "$OUT"
