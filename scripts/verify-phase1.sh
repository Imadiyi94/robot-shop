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
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $HOST" "http://localhost:$INGRESS_PORT/" || echo 000)
check "HTTP status" 200 "$code"
body=$(curl -s --max-time 15 -H "Host: $HOST" "http://localhost:$INGRESS_PORT/" | grep -c -i 'robot' || true)
if [ "$body" -gt 0 ]; then pass "storefront content contains 'robot'"; else fail "storefront content unexpected"; fi

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
