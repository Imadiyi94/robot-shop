#!/usr/bin/env bash
# Phase 1 acceptance checks for Stan's Robot Shop.
#
# Requires kubectl and a reachable cluster (KUBECONFIG). Read-only: every call is
# a get/wait/exec/logs. Run from the repository root.
#
# Usage: bash scripts/verify-phase1.sh
set -uo pipefail

NS="${NS:-robot-shop}"
HOST="${HOST:-robot-shop.local}"
INGRESS_PORT="${INGRESS_PORT:-30080}"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1 -> $3"; else fail "$1 -> expected $2, got $3"; fi; }

echo "== rollout =="
for d in $(kubectl -n "$NS" get deploy -o name); do
  if kubectl -n "$NS" rollout status "$d" --timeout=240s >/dev/null 2>&1; then
    pass "$d available"
  else
    fail "$d not available"
  fi
done
kubectl -n "$NS" rollout status statefulset/redis --timeout=240s >/dev/null 2>&1 \
  && pass "statefulset/redis ready" || fail "statefulset/redis not ready"

echo
echo "== pods =="
expected="${EXPECTED_PODS:-13}"
ready=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -c ' Running ')
check "pods Running" "$expected" "$ready"
not_ready=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -vc ' Running ')
check "pods not Running" 0 "$not_ready"

echo
echo "== images pinned by digest =="
pinned=$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep -c '@sha256:')
check "digest-pinned containers" "$expected" "$pinned"

echo
echo "== Instana disabled =="
instana=$(kubectl -n "$NS" get deploy,statefulset -o yaml 2>/dev/null | grep -c 'INSTANA_' || true)
check "INSTANA_ references" 0 "$instana"

echo
echo "== no load balancer =="
lb=$(kubectl -n "$NS" get svc -o yaml 2>/dev/null | grep -c 'type: LoadBalancer' || true)
check "LoadBalancer services" 0 "$lb"

echo
echo "== storefront over ingress =="
# The request must go through the shared ingress-nginx controller, i.e. the
# NodePort it owns. Which host address answers it is not always `localhost`:
# on this workstation a stale WSL relay holds 127.0.0.1:30080 and accepts then
# drops connections, while Docker's 0.0.0.0 binding on the LAN address works.
# Try the candidates in order and report which one answered, so a genuine
# routing failure stays distinguishable from a broken host port-forward.
fetch() { curl -s --max-time 15 -H "Host: $HOST" "http://$1:$INGRESS_PORT$2"; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $HOST" "http://$1:$INGRESS_PORT$2"; }
host_lan_ip() {
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.IPAddress -notlike '169.*' -and \$_.InterfaceAlias -notlike '*Loopback*' } | Select-Object -First 1).IPAddress" 2>/dev/null | tr -d '\r'
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

addr=""
for cand in ${INGRESS_ADDR:-} localhost 127.0.0.1 "$(host_lan_ip)"; do
  [ -z "$cand" ] && continue
  if [ "$(http_code "$cand" /)" = "200" ]; then addr="$cand"; break; fi
done

if [ -z "$addr" ]; then
  fail "HTTP status -> no address answered on port $INGRESS_PORT (tried localhost, 127.0.0.1, LAN IP)"
else
  pass "HTTP status -> 200 via $addr:$INGRESS_PORT"
  [ "$addr" = "localhost" ] || echo "        note: 'localhost' did not answer; probing $addr instead"
fi
body=$([ -n "$addr" ] && fetch "$addr" / | grep -c -i 'robot' || true)
if [ "${body:-0}" -gt 0 ]; then pass "storefront content contains 'robot'"; else fail "storefront content unexpected"; fi

echo
echo "== load generator =="
logs=$(kubectl -n "$NS" logs deploy/load --tail=30 2>/dev/null || true)
if [ -n "$logs" ]; then pass "load pod is producing log output"; else fail "no load logs"; fi
echo "$logs" | tail -5 | sed 's/^/        /'

echo
echo "== PVC =="
kubectl -n "$NS" get pvc --no-headers 2>/dev/null | sed 's/^/        /'

echo
if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "All Phase 1 checks passed."
