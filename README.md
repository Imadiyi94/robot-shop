# Stan's Robot Shop - Capstone 2

Self-hosted observability stack for the `instana/robot-shop` demo application,
running on the Kind cluster built in Capstone 1.

> **Status:** Step 2 complete - chart vendored and offline-validated.
> No cluster resources created yet.

## Cluster inheritance

This repository does **not** create infrastructure. It consumes the existing
multi-node Kind cluster from Capstone 1:

| Item | Value |
| --- | --- |
| Kubeconfig | `../example-voting-app/terraform/kubeconfig-voting-app` |
| Context | `kind-voting-app` |
| Ingress | shared `ingress-nginx` controller, NodePort `30080` |

`deploy.sh` refuses to run unless that context and its Ready nodes are present,
so a stale `KUBECONFIG` cannot silently target the wrong cluster.

## Layout

```
helm/robot-shop/          vendored upstream chart (patched, see UPSTREAM.md)
  values-phase1.yaml      namespace-free overlay: Instana off, Ingress, loadgen
terraform/                namespace, quota, network policy (Step 3)
scripts/verify-render.sh  offline helm lint/template + rendered-output asserts
scripts/pull-images.ps1   retrying Docker Hub puller; records digests
scripts/load-images.ps1   loads images into every Kind node and tags by digest
scripts/import-image.sh   platform-pinned fallback when `kind load` fails
scripts/verify-phase1.sh  live acceptance: rollout, pods, digests, ingress, load
docs/IMPLEMENTATION_PLAN.md
docs/IMAGE_PINS.md        image -> digest record with resolve date
docs/phase1-verification.log  captured Phase 1 acceptance run
docs/upstream/            pristine upstream references kept for provenance
```

Remote: <https://github.com/Imadiyi94/robot-shop>

## Phase 1 is live

```bash
export KUBECONFIG=../example-voting-app/terraform/kubeconfig-voting-app
helm upgrade --install robot-shop helm/robot-shop -n robot-shop -f helm/robot-shop/values-phase1.yaml
bash scripts/verify-phase1.sh
```

13 pods, all `Ready`, 0 restarts; storefront served through the shared
ingress-nginx controller.

> **`localhost:30080` may not answer on this workstation.** A stale `wslrelay`
> process holds `127.0.0.1:30080` and drops connections, while Docker's `0.0.0.0`
> binding on the host LAN address works. `verify-phase1.sh` probes several
> addresses and prints which one answered. See
> `docs/IMPLEMENTATION_PLAN.md` § 11. This affects Capstone 1 on the same port.

## Validate (no cluster access)

```bash
bash scripts/verify-render.sh
```

The script runs `helm lint --strict` on both value sets, renders the manifests
into `dist/`, then asserts the properties that matter: zero `INSTANA_`
variables, no `LoadBalancer`, ClusterIP web Service, Ingress on
`robot-shop.local`, 7 readiness probes, 12 Deployments, load generator present,
and that flipping `instana.enabled=true` restores the agent environment.
(7, not 8: dispatch is a queue consumer with no listener, so it cannot be probed.)

## Design notes

* **Instana is gated, not removed.** Upstream has no `instana.enabled` key, so
  the chart is vendored and every Instana surface is wrapped in that flag.
  Default is `false`.
* **Readiness probes only.** A failing liveness probe restarts container
  processes whose health route is unverified; readiness simply removes the pod
  from the Service and keeps the page served.
* **`web` is a ClusterIP.** Upstream defaults to `LoadBalancer`, which never
  gets an address on Kind.
* **No secrets in git.** Grafana credentials stay in a git-ignored local file.
