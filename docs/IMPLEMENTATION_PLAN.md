# Capstone 2 — Implementation Plan (Phase 1 & Phase 2)

Status: **decisions resolved 2026-10-26**. No build, deploy, or Helm commands have been run.

Source PRD: `../Capstone 2/PRD_Stan's_Robot_Shop.md`

---

## 0. Verified starting point

Everything below was read from the live environment, not assumed.

| Fact | Value |
| --- | --- |
| Cluster | `voting-app` (Kind), 3 nodes, all `Ready` |
| Context | `kind-voting-app` |
| Kubeconfig | `../example-voting-app/terraform/kubeconfig-voting-app` |
| Nodes | 1 control-plane + 2 workers, **14 CPU / 3.7Gi RAM / 110 pods** allocatable each |
| Ingress | `ingress-nginx` controller, NodePort **30080**/30443, metrics service present |
| Storage | default class `standard` (`rancher.io/local-path`), `WaitForFirstConsumer` |
| Existing releases | `voting-app` (rev 11), `nginx-ingress` |
| Monitoring CRDs | **none installed** — no Prometheus operator yet |
| Namespaces | `default`, `ingress-nginx`, `kube-*`, `local-path-storage`, `voting-app` |

Upstream facts (instana/robot-shop @ `master`, archived):

* Helm chart lives at **`K8s/helm`**, not `helm/robot-shop`.
* Chart values are only: `image`, `eum`, `psp`, `nodeport`, `openshift`, `ocCreateRoute`, `redis.storageClassName`, per-workload affinity.
* **`instana.enabled` does not exist upstream.** Instana wiring is hard-coded in templates (`INSTANA_AGENT_HOST` on `cart`, EUM env on `web`). The PRD's requirement therefore needs a small vendored patch, described in Phase 1.
* `web` Service defaults to `type: LoadBalancer` unless `nodeport=true`; on Kind that leaves an external IP pending. We will use ClusterIP + Ingress.
* `mongodb` and `mysql` have **no volumes** (ephemeral); `redis` is a StatefulSet with a 1Gi PVC.
* Only **cart** and **payment** expose `/metrics`. `web`/`catalogue` need gateway + Kubernetes metrics for RED panels.
* Upstream images: `robotshop/rs-{web,cart,catalogue,payment,user,shipping,ratings,dispatch,mongodb,mysql-db,rabbitmq,load}:latest` plus `redis:4.0.6`.

---

## 1. Constraints

1. **Do not create, recreate, or delete the Kind cluster.** Capstone 2 consumes it.
2. **Do not modify Capstone 1.** The only cross-boundary action is reading
   `../example-voting-app/terraform/kubeconfig-voting-app`.
3. The existing ingress controller is **shared**; we add Ingress *rules* only.
4. Namespace isolation is Terraform's job; workloads are Helm's job (same split as Capstone 1).
5. Secrets never enter git.
6. This document covers **Phase 1 and Phase 2 only**. Phases 3–6 are scoped later.

---

## 2. Workspace and repository layout

```
robot-shop/
├── opencode.json                     # created (cross-repo reference)
├── README.md                         # quick start + architecture
├── deploy.sh                         # cluster guard → Terraform → Helm
├── terraform/
│   ├── main.tf                       # provider from existing kubeconfig only
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── namespace/                # robot-shop NS, quota, limit range, netpol
│       └── monitoring/               # kube-prometheus-stack + dashboards chart
├── helm/
│   ├── robot-shop/                   # vendored upstream chart, patched
│   │   ├── UPSTREAM.md               # source commit + list of patches
│   │   ├── values.yaml
│   │   └── templates/...
│   └── robot-shop-observability/     # ServiceMonitors, dashboards, exporter
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── dashboards/*.json
│       └── templates/*.yaml
├── scripts/
│   ├── load.sh                       # toggle/verify the load generator
│   ├── verify-phase1.sh
│   └── verify-phase2.sh
└── docs/
    ├── IMPLEMENTATION_PLAN.md        # this file
    ├── PHASE1.md
    └── PHASE2.md
```

Proposed: `git init` here and push to `github.com/Imadiyi94/robot-shop`
(decision D6).

---

## 3. Cluster inheritance (no new cluster)

The PRD (§1.0) states Capstone 2 runs on "the pre-existing Amazon EKS cluster
instance". That is not what exists here: Capstone 1 provisioned a local multi-node
Kind cluster, and the explicit instruction for this capstone is to inherit it and
**not** create another cluster. So the target is the existing `voting-app` Kind
cluster. Everything else the PRD asks for (namespace isolation, Instana disabled,
Prometheus/Grafana, synthetic load) is platform-agnostic and unaffected. If an
EKS target is ever required, only `kubeconfig_path` / `kube_context` change —
no manifest in this repository is Kind-specific.

**Terraform provider** — no cluster resources at all:

```hcl
provider "kubernetes" {
  config_path    = var.kubeconfig_path   # ../example-voting-app/terraform/kubeconfig-voting-app
  config_context = var.kube_context      # kind-voting-app
}
provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
```

**`deploy.sh` guard** (fails fast, never creates):

1. Resolve `KUBECONFIG` (env override → cross-repo default).
2. `kubectl get nodes` → require ≥ 2 `Ready` nodes.
3. `kubectl config current-context` → require `kind-voting-app`.
4. Require the `ingress-nginx` controller pod to exist; if absent, stop with
   instructions (do not silently install a second controller).
5. Only then run `terraform apply` and `helm upgrade --install`.

Optional hardening: a Terraform `check` block that asserts node count so CI
also fails if pointed at the wrong cluster.

---

## 4. Phase 1 — Namespace, vendor-free Instana, load

PRD 3.1 / Deliverable 1.

### 4.1 Terraform: `modules/namespace`

| Object | Detail |
| --- | --- |
| `kubernetes_namespace_v1` | name `robot-shop`; labels `app.kubernetes.io/part-of=robot-shop`, `environment=local` |
| Pod Security | enforce **baseline**, audit/warn `restricted` (upstream images run as root; `restricted` would block them) |
| `kubernetes_resource_quota_v1` | `requests.cpu=4`, `requests.memory=5Gi`, `limits.cpu=8`, `limits.memory=8Gi`, `pods=35`, `services=20`, `configmaps=20`, `secrets=20`, `pvc=5` |
| `kubernetes_limit_range_v1` | default request 100m/128Mi, default limit 500m/512Mi, max 2 CPU/2Gi |
| `kubernetes_network_policy_v1` | default-deny (ingress + egress); allow DNS; allow intra-namespace; allow ingress from `ingress-nginx` to `web:8080` only; allow `payment` egress on 443 to public space |

Quota rationale (chart defaults, as built in Step 3):

| Tier | Requests | Limits |
| --- | --- | --- |
| web, catalogue, cart, payment, user, ratings, dispatch (7 × 100m/50Mi) | 700m / 350Mi | 1400m / 700Mi |
| shipping (Java) | 100m / **500Mi** | 200m / **1000Mi** |
| mongodb | 100m / 100Mi | 200m / 200Mi |
| mysql | 100m / **700Mi** | 200m / **1024Mi** |
| rabbitmq | 100m / 256Mi | 200m / 512Mi |
| redis | 100m / 50Mi | 200m / 100Mi |
| load | 100m / 100Mi | 200m / 200Mi |
| **steady total (13 pods)** | **1.3 CPU / 2.0Gi** | **2.6 CPU / 3.55Gi** |
| **rollout peak (+12 surge pods)** | **~2.5 CPU / 4.1Gi** | **~5.0 CPU / 7.3Gi** |

The quota is sized to the **rollout peak**, not the steady state: a `helm upgrade`
rolls all 12 Deployments at once, and a quota at steady-state totals would reject
the surge pods mid-upgrade. 4 CPU / 5Gi requests and 8 CPU / 8Gi limits leave
headroom above the peak without letting this namespace starve `voting-app`.

### 4.2 Vendored chart + `instana.enabled=false`

Because upstream has no such key, vendor `K8s/helm` at a pinned commit and record it
in `UPSTREAM.md`. Patches (each kept minimal so future upstream diffs are readable):

1. **Add `instana.enabled: false`** to `values.yaml` (default false = vendor-free).
2. **Gate every Instana surface** behind it:
   - `cart`: `INSTANA_AGENT_HOST`
   - `web`: `INSTANA_EUM_KEY` / `INSTANA_EUM_REPORTING_URL`
   - any other `INSTANA_*` env found by `grep -rn INSTANA templates/`
   - no Instana agent/daemonset is installed by this chart today, and the
     toggle guarantees none is rendered later.
3. **Web exposure**: ClusterIP (not LoadBalancer/NodePort) + new `ingress.yaml`
   (`robot-shop.local` → `web:8080`, class `nginx`, no TLS redirect).
4. **Load generator**: new `load-deployment.yaml` template gated by `loadgen.enabled`
   (`HOST=http://web:8080/`, `NUM_CLIENTS=15`, `SILENT=1`, `ERROR=1`) — mirrors
   upstream `K8s/load-deployment.yaml`.
5. **Probes** (recommended): readiness/liveness on `web` and `catalogue` (HTTP),
   TCP on data services. Upstream has none; without them Phase 5's availability
   SLO has no signal.
6. **Image pinning**: resolve `latest` to digests for the 13 upstream images and
   pin them, matching Capstone 1 practice (decision D7).

`values-phase1.yaml`:

```yaml
instana:
  enabled: false
image:
  repo: robotshop
  version: "<pinned>"
nodeport: false
ingress:
  enabled: true
  className: nginx
  host: robot-shop.local
loadgen:
  enabled: true
  clients: 15
redis:
  storageClassName: standard
```

### 4.3 Image availability

Kind nodes pull from Docker Hub on their own and Capstone 1 already showed DNS
flakiness. Plan: `docker pull` the 13 app images on the host, then
`kind load docker-image ... --name voting-app`, and set `imagePullPolicy: IfNotPresent`.
This also avoids Docker Hub rate limits on 3 nodes.

### 4.4 Phase 1 acceptance

```bash
kubectl -n robot-shop get pods                  # 13/13 Ready (8 app pods + mongodb + mysql + rabbitmq + redis + load)
curl -H 'Host: robot-shop.local' http://localhost:30080/   # 200 + store HTML
kubectl -n robot-shop logs deploy/load --tail=20            # continuous requests
kubectl -n robot-shop get deploy,ds | grep -i instana       # empty
helm get manifest robot-shop -n robot-shop | grep -c INSTANA # 0
```

Evidence saved to `docs/phase1-verification.log`.
Deliverable 1 (live app under automated load) is met when the load pods have been
running for ≥ 10 minutes with no CrashLoopBackOff.

---

## 5. Phase 2 — Metrics platform and dashboards as code

PRD 3.2 / Deliverable 2.

### 5.1 `kube-prometheus-stack` (Terraform `helm_release`)

Namespace `monitoring`, chart version pinned. Values (`monitoring/values-prod.yaml`):

```yaml
prometheus:
  prometheusSpec:
    retention: 7d                 # strict 7-day cleanup
    retentionSize: 2GB            # cap disk on a laptop
    walCompression: true
    scrapeInterval: 30s
    # no storageSpec -> emptyDir (persistence removed per PRD)
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorNamespaceSelector: {}
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { cpu: 500m, memory: 1Gi }
grafana:
  persistence: { enabled: false }
  adminPassword: <from git-ignored secret>
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: ALL
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts: [grafana.local]
alertmanager:
  enabled: true
  alertmanagerSpec:
    resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 100m, memory: 128Mi } }
    # no storage -> ephemeral
kubeEtcd:            { enabled: false }   # Kind control-plane endpoints are not scrapable
kubeControllerManager: { enabled: false }
kubeScheduler:       { enabled: false }
kubeProxy:           { enabled: false }
nodeExporter:        { enabled: true }
kubeStateMetrics:    { enabled: true }
```

Alertmanager stays enabled now (Phase 5 will configure receivers); it is cheap and
avoids a second stack install later.

### 5.2 `robot-shop-observability` chart (Terraform `helm_release`, depends on stack)

* **ServiceMonitors**: `cart` and `payment`, path `/metrics`, port `http`,
  selector `service: cart|payment`, namespace `robot-shop`.
* **Ingress/gateway metrics**: the existing `ingress-nginx` controller metrics
  service is already in the cluster (port 10254); add a `ServiceMonitor` only if
  the controller did not create one (it does by default, so this is a no-op check).
* **RabbitMQ backlog**: add a small `rabbitmq-exporter` deployment + ServiceMonitor
  (`kbudde/rabbitmq-exporter`) pointing at `rabbitmq:15672`, **if** the
  `rs-rabbitmq` image exposes the management plugin. Spike in step 1; fallback is
  documented in D4.
* **Dashboards**: JSON files rendered into ConfigMaps labelled
  `grafana_dashboard: "1"` and annotated
  `grafana_folder: Robot Shop`, so the Grafana sidecar discovers them with no UI work.

### 5.3 Required panels (PRD 3.2)

Each dashboard is a ConfigMap rendered from `dashboards/*.json`.

| # | Dashboard | Primary queries |
| --- | --- | --- |
| 1 | Request rate | `sum(rate(nginx_ingress_controller_requests{namespace="robot-shop"}[5m])) by (service)`; `rate(cart_items_added_total[5m])`; `rate(payment_transactions_total[5m])` |
| 2 | Error rate | 5xx ratio over `nginx_ingress_controller_requests`; per-service breakdown |
| 3 | Latency | `histogram_quantile(0.95, sum(rate(nginx_ingress_controller_request_duration_seconds_bucket{namespace="robot-shop"}[5m])) by (le, service))` |
| 4 | Saturation | `container_memory_working_set_bytes` vs limits; `rate(container_cpu_usage_seconds_total[5m])` vs limits, per pod |
| 5 | Data health | `up{namespace="robot-shop"}`; pod restart counts; deployment availability; RabbitMQ queue depth (or documented fallback) |

Deliver as **five focused dashboards + one overview** that links to them
(decision D2).

### 5.4 Phase 2 acceptance

```bash
kubectl -n monitoring get pods                              # all Ready
kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.retention}'   # 7d
kubectl -n monitoring get deploy kube-prometheus-stack-operator -o yaml | grep -c storageSpec  # 0
curl -s 'http://localhost:9090/api/v1/targets?state=active' | jq '.data.activeTargets[] | select(.labels.namespace=="robot-shop") | .health'
curl -s http://grafana.local:30080/api/search?query=Robot | jq '.[].title'
```

Evidence saved to `docs/phase2-verification.log`, including:
* Prometheus target count for `robot-shop` and all `up`.
* Retention argument + absence of PVCs for Prometheus/Grafana.
* Grafana sidecar import log and dashboard titles.

---

## 6. Execution order

| Step | Action | Gate |
| --- | --- | --- |
| 1 | Approve plan + decisions D1–D8 | **done 2026-10-26** |
| 2 | Scaffold repo, vendor chart, apply patches | `helm lint` / `helm template` |
| 3 | Terraform namespace module | `terraform validate` + plan shows **0 cluster resources** |
| 4 | Build/load/pin images | all 13 images present in Kind |
| 5 | Helm install Phase 1 + loadgen | 13 pods Ready, HTTP 200, load logs |
| 6 | Terraform monitoring + observability chart | Prometheus/Grafana Ready |
| 7 | Dashboards + ServiceMonitors | targets UP, dashboards visible |
| 8 | Evidence logs + docs | review |

Estimated effort: Phase 1 ≈ 1 session; Phase 2 ≈ 1 session.

---

## 7. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Docker Hub rate limit / Kind DNS flakiness | host pull + `kind load`, `IfNotPresent`, pinned digests |
| Memory pressure (3.7Gi × 3 nodes) | quotas, small Prometheus, `retentionSize: 2GB`, no persistence |
| `instana.enabled` absent upstream | vendored patch, documented in `UPSTREAM.md` |
| PSA restricted would reject root images | enforce `baseline` only |
| Web Service defaults to LoadBalancer | patch to ClusterIP + Ingress |
| Kind cannot scrape control-plane components | disable etcd/scheduler/controller-manager jobs |
| RabbitMQ management endpoint unknown | spike first; fallback documented |
| Shared ingress controller | reuse, never reinstall |

---

## 8. Decisions (resolved 2026-10-26)

| ID | Decision | Outcome |
| --- | --- | --- |
| D1 | `instana.enabled` does not exist upstream | **Vendor + patch** the chart at a pinned commit; gate all `INSTANA_*` env behind `instana.enabled`; log every patch in `UPSTREAM.md` |
| D2 | Dashboard layout | **5 focused dashboards + 1 overview** that links to them |
| D3 | Who installs `kube-prometheus-stack` | **Terraform `helm_release`** — monitoring is infrastructure, version pinned in code, torn down by `terraform destroy` |
| D4 | RabbitMQ backlog source | **Spike `kbudde/rabbitmq-exporter`**; if the management endpoint is absent, fall back to pod health + restart counts and document why in `PHASE2.md` |
| D5 | Grafana admin password | **Git-ignored local secret file**, never in values or git |
| D6 | Repository | **`git init` in `robot-shop/`** and push to a new GitHub remote |
| D7 | Image tag strategy | **Pin all 13 app images by digest** (`imagePullPolicy: IfNotPresent`) |
| D8 | mongo/mysql persistence | **Keep upstream ephemeral**; revisit only if a later phase needs storage drills |

Consequences carried into implementation:

* D1 makes `helm/robot-shop` a maintained fork — `UPSTREAM.md` must record the exact
  upstream commit and a numbered patch list, and every patch stays minimal so
  upstream diffs remain readable.
* D3 means `terraform/` owns two releases (`kube-prometheus-stack`, then
  `robot-shop-observability` with an explicit `depends_on`), so CRDs exist before
  ServiceMonitors are applied.
* D7 adds a pre-flight step: resolve digests for all 13 images and record them in
  `values.yaml` plus `docs/IMAGE_PINS.md` with the resolve date.

---

## 9. Step 2 outcome — vendoring and offline validation (2026-10-26)

Vendored at `55292e2199f2fb00a165b1f7d3045fe7f8922038` into `helm/robot-shop/`.
Patch set P1–P5 and the full provenance table live in `helm/robot-shop/UPSTREAM.md`.

### Corrections to earlier assumptions

Reading all 30 upstream templates changed four facts the plan had wrong. They are
recorded here rather than silently fixed:

| Earlier assumption | Actual |
| --- | --- |
| Only `cart` carries `INSTANA_AGENT_HOST` | **Five** services do: cart, catalogue, dispatch, payment, user. A one-file patch would have left four agent lookups pointed at a host with no agent. |
| No upstream readiness probes | `ratings` (`/_health:80`) and `shipping` (`/health:8080`) already have them; six services needed them added. |
| RabbitMQ backlog source unverified (D4) | Upstream runs `rabbitmq:3.7-management-alpine` and the Service already publishes `http-management` on **15672**. D4 is resolved without a custom image or exporter-side workaround. |
| robot-shop requests ≈ 1.3 CPU / 1.45Gi, limits ≈ 2.5Gi | `shipping` requests 500Mi and `rabbitmq` 256Mi, both missed earlier. Real totals: **1.3 CPU / 2.0Gi requests**, **2.6 CPU / 3.55Gi limits**. Quota (6Gi / 10Gi) still absorbs it; the memory margin is thinner than stated. |

### Validation performed (zero cluster contact)

`scripts/verify-render.sh` runs inside Git Bash with an offline-only toolchain:

* `helm lint --strict` on default values and on `values-phase1.yaml` — both clean
  (one `[INFO]` about a missing icon).
* `helm template` renders three variants: defaults, Phase 1, and
  `instana.enabled=true`.
* 15 assertions, all passing: 0 `INSTANA_` variables, 0 `LoadBalancer`, web
  Service `ClusterIP`, Ingress on `robot-shop.local`, 8 readiness probes, 12
  Deployments, load generator present, 1Gi redis PVC, opt-in features absent by
  default, and — with the flag flipped on — 5 `INSTANA_AGENT_HOST` entries plus
  1 `INSTANA_EUM_KEY`.

That last assertion is the important one: it proves the gate is a switch, not a
deletion.

### Known gaps at end of Step 2

* **Image digests not yet pinned** — still `latest`. Deliberate; Step 4 (D7).
* **No Kubernetes schema validation offline.** `kubectl apply --dry-run=client`
  requires API discovery even with `--validate=false`; it was attempted against
  a throwaway kubeconfig pointing at `127.0.0.1:1` and failed with `error: EOF`,
  touching nothing. Schema conformance is therefore proven at install time in
  Phase 1, or by adding `kubeconform` to CI.
* **PSP templates left untouched** — `policy/v1beta1` is unrenderable on
  Kubernetes ≥ 1.25, so `psp.enabled` must stay `false` (PSA `baseline` covers it).

---

## 10. Step 3 outcome — namespace module (2026-10-26)

Written: `terraform/{main,variables,outputs}.tf` and
`terraform/modules/namespace/{main,variables,outputs}.tf`.

| Check | Result |
| --- | --- |
| `terraform init` | success (provider 2.38.0, offline mirror) |
| `terraform validate` | **Success** |
| `terraform fmt -check -recursive` | clean, exit 0 |
| `terraform plan` | **8 to add, 0 to change, 0 to destroy** |
| Resources planned | 1 Namespace, 1 ResourceQuota, 1 LimitRange, 5 NetworkPolicies |

**Zero-write proof:** `kubectl get namespace robot-shop` returned `NotFound` both
immediately before and immediately after `terraform plan`. The plan file
(`dist/phase1.tfplan`) is local, and `terraform plan` performs reads only.

### NetworkPolicy enforcement gap — read this before claiming isolation

The inherited cluster runs **kindnetd `v20240202`**, which does not implement
NetworkPolicy. The five policies are created and syntactically valid, but they
are **not enforced**: nothing currently restricts pod-to-pod traffic in
`robot-shop`. This is not a regression — `voting-app`'s three Capstone 1 policies
are equally inert.

Authoring them is still the right call: the PRD asks for the guardrail as code,
and they take effect the moment a policy-capable CNI is installed. Two traps are
recorded for whoever does that:

1. **Kubelet probes break.** Under default-deny ingress, readiness/liveness
   probes are denied (they originate from the node IP), so every pod would go
   `NotReady`. An `allow-kubelet-probes` policy on the node CIDR is mandatory in
   the same change.
2. **Prometheus scraping breaks.** Phase 2 must add an `allow-monitoring-scrape`
   policy from the `monitoring` namespace to the app ports, or every target will
   read `down`.

### Offline provider install (workstation-specific)

`registry.terraform.io` does not resolve on this network, so a plain
`terraform init` fails with `no such host`. Provider 2.38.0 is served from
Capstone 1's existing cache through a `filesystem_mirror` CLI config
(`TF_CLI_CONFIG_FILE`). CI uses the public registry normally. This is an
environment quirk, not a configuration defect — see `terraform/README.md`.

### Phase 2 prerequisite

ServiceMonitors select pods by label and scrape by **named port**. `cart` and
`payment` already expose `port: http`, so no Service change is needed. The
`monitoring` namespace and its NetworkPolicy allowance are Phase 2 work.
