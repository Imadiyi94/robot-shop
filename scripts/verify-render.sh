#!/usr/bin/env bash
# Offline validation for the vendored robot-shop chart.
#
# Guarantees: no cluster access. Every check is `helm lint` / `helm template`
# plus grep over the rendered output, so it is safe to run before Phase 1 and
# in CI without a kubeconfig.
#
# Usage: bash scripts/verify-render.sh
set -euo pipefail

CHART="${CHART:-helm/robot-shop}"
OUT="${OUT:-dist}"
failures=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { # label expected actual
  if [ "$2" = "$3" ]; then pass "$1 -> $3"; else fail "$1 -> expected $2, got $3"; fi
}
count() { grep -c "$1" "$2" 2>/dev/null || true; }

mkdir -p "$OUT"

echo "== helm lint (strict): default values =="
helm lint --strict "$CHART"

echo "== helm lint (strict): Phase 1 overlay =="
helm lint --strict "$CHART" -f "$CHART/values-phase1.yaml"

echo "== render =="
helm template robot-shop "$CHART" --namespace robot-shop -f "$CHART/values-phase1.yaml" >"$OUT/phase1.yaml"
helm template robot-shop "$CHART" --namespace robot-shop >"$OUT/defaults.yaml"
helm template robot-shop "$CHART" --namespace robot-shop --set instana.enabled=true --set eum.key=probe-key >"$OUT/instana-on.yaml"
echo "  wrote $OUT/{phase1,defaults,instana-on}.yaml"

echo "== Phase 1 render assertions =="
check "no INSTANA_ env vars"        0 "$(count 'INSTANA_' "$OUT/phase1.yaml")"
check "no LoadBalancer Service"     0 "$(count 'type: LoadBalancer' "$OUT/phase1.yaml")"
check "web Service is ClusterIP"    1 "$(count 'type: ClusterIP' "$OUT/phase1.yaml")"
check "Ingress host"                1 "$(count 'host: robot-shop.local' "$OUT/phase1.yaml")"
check "readiness probes"            8 "$(count 'readinessProbe' "$OUT/phase1.yaml")"
check "Deployments rendered"       12 "$(count '^kind: Deployment' "$OUT/phase1.yaml")"
check "load generator present"      1 "$(count '^  name: load$' "$OUT/phase1.yaml")"
check "redis PVC size"              1 "$(count 'storage: 1Gi' "$OUT/phase1.yaml")"

echo "== default render assertions (opt-in features stay off) =="
check "no INSTANA_ by default"      0 "$(count 'INSTANA_' "$OUT/defaults.yaml")"
check "no Ingress by default"       0 "$(count '^kind: Ingress' "$OUT/defaults.yaml")"
check "no loadgen by default"       0 "$(count '^  name: load$' "$OUT/defaults.yaml")"

echo "== gating assertion: instana.enabled=true must restore agent env =="
check "INSTANA_AGENT_HOST x5"       5 "$(count 'INSTANA_AGENT_HOST' "$OUT/instana-on.yaml")"
check "INSTANA_EUM_KEY restored"    1 "$(count 'INSTANA_EUM_KEY' "$OUT/instana-on.yaml")"

echo
if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures assertion(s)"
  exit 1
fi
echo "All checks passed."
