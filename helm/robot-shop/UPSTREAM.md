# Upstream provenance and patch log

This chart is a **vendored copy** of `instana/robot-shop`, not a fork on GitHub.
It exists because the PRD requires `instana.enabled=false`, and upstream has no
such value — Instana wiring is hard-coded in the templates.

## Source

| Field | Value |
| --- | --- |
| Repository | https://github.com/instana/robot-shop (archived, read-only) |
| Commit | `55292e2199f2fb00a165b1f7d3045fe7f8922038` |
| Chart path | `K8s/helm` (not `helm/robot-shop`) |
| Upstream chart version | `1.1.0`, `apiVersion: v1` |
| Load generator reference | `K8s/load-deployment.yaml`, copied to `docs/upstream/load-deployment.yaml` |
| Vendored on | 2026-10-26 |

Extraction command (kept out of this repo's history):

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/instana/robot-shop /tmp/robot-shop-upstream
git -C /tmp/robot-shop-upstream sparse-checkout set --no-cone "K8s/helm/*" "K8s/load-deployment.yaml"
```

## Patches applied

Every patch is marked with a `PATCH <n>` comment in the file it touches, so
`grep -rn "PATCH " helm/robot-shop` lists the complete delta.

| # | Patch | Files |
| --- | --- | --- |
| **P1** | Instana deactivation. New `instana.enabled` value (default `false`). Gates `INSTANA_AGENT_HOST` on **cart, catalogue, dispatch, payment, user** and `INSTANA_EUM_*` on **web**. `payment` keeps its own `PAYMENT_GATEWAY` env by rendering `env:` when either switch is set. | `values.yaml`, `cart-deployment.yaml`, `catalogue-deployment.yaml`, `dispatch-deployment.yaml`, `payment-deployment.yaml`, `user-deployment.yaml`, `web-deployment.yaml` |
| **P2** | Readiness probes on the six services that had none (upstream only probes `ratings` and `shipping`). HTTP where a verified route exists (`/` web, `/catalogue`, `/metrics` cart + payment); TCP for `user` and `dispatch`, where an unknown route would 404 and fail the probe. No liveness probes: an unverified liveness route turns a transient dependency failure into a restart loop. | `web/catalogue/cart/payment/user/dispatch-deployment.yaml` |
| **P3** | Ingress exposure. `web` Service type via `web.service.type` (default `ClusterIP`, `nodeport` still wins), plus a new `ingress.yaml` gated on `ingress.enabled`. | `values.yaml`, `web-service.yaml`, `ingress.yaml` (new) |
| **P4** | Synthetic load generator at `loadgen.*`, gated on `loadgen.enabled`. Mirrors upstream `K8s/load-deployment.yaml` including `ERROR=1` so a failed request does not kill the run. | `values.yaml`, `load-deployment.yaml` (new) |
| **P5** | Chart metadata: `apiVersion: v2` (upstream `v1` is legacy), `version: 1.2.0`, `appVersion: 1.1.0`, `sources:` and an `capstone2/upstream-commit` annotation so the vendor point is machine-readable. | `Chart.yaml` |
| **P6** | Digest pinning (decision D7). New `robot-shop.image` helper renders `repo/name:tag@sha256:...` when `image.digests[<name>]` is set, and falls back to the plain tag otherwise. `redis` and `rabbitmq` images become configurable (`redis.image`, `rabbitmq.image`) because upstream hard-codes `redis:4.0.6` and `rabbitmq:3.7-management-alpine` in the templates. | `_helpers.tpl` (new), all 11 `rs-*` deployment templates, `redis-statefulset.yaml`, `rabbitmq-deployment.yaml`, `values.yaml` |

## Deliberately not patched

* **PSP / RBAC templates** (`podsecuritypolicy.yaml`, `clusterrole*.yaml`,
  `serviceaccount.yaml`) use `policy/v1beta1`, removed in Kubernetes 1.25. They
  are impossible to render on the target cluster and must stay behind
  `psp.enabled=false`. Pod Security Admission (`baseline`, set by Terraform)
  replaces them. That is why `serviceaccount.yaml`'s hard-coded
  `namespace: robot-shop` is left alone rather than templated.
* **Ephemeral `mongodb` / `mysql`.** No volumes upstream; kept as-is (decision
  D8). Only `redis` has a 1Gi PVC.
* **Resource requests/limits** are untouched, so the quota math in
  `docs/IMPLEMENTATION_PLAN.md` stays a direct function of upstream.

## Upstream facts to know before operating this chart

* **Five** services carry `INSTANA_AGENT_HOST`, not one — a partial patch would
  have left four agents pointed at a host with no agent.
* `ratings` (`/_health:80`) and `shipping` (`/health:8080`) already had
  readiness probes upstream; P2 does not duplicate them.
* RabbitMQ is `rabbitmq:3.7-management-alpine` and the Service already publishes
  `http-management` on **15672**. The management plugin is therefore available,
  which satisfies decision D4 without a custom image — the Phase 2 exporter can
  scrape `rabbitmq:15672`.
* `web` renders **two** objects from one template file (Service + optional
  OpenShift Route); `ocCreateRoute` stays `false`.
* Images are all `robotshop/rs-*:latest` plus `redis:4.0.6` and
  `rabbitmq:3.7-management-alpine` — 13 references in total. The two
  non-`robotshop` images were hard-coded in the templates until P6 made them
  values-driven; digest pinning is applied per environment via
  `values-phase1.yaml` and recorded in `docs/IMAGE_PINS.md`.

## Re-vendoring procedure

1. Re-run the sparse clone against a new upstream commit.
2. Copy `K8s/helm/*` over `helm/robot-shop/`, then re-apply P1-P6 (the `PATCH`
   markers in the current files are the specification).
3. Update the commit in this file and in `Chart.yaml`'s annotation.
4. Run `bash scripts/verify-render.sh`; it fails if the Instana gating or probe
   count regresses.
