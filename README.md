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
docs/IMPLEMENTATION_PLAN.md
docs/IMAGE_PINS.md        image -> digest record with resolve date
docs/upstream/            pristine upstream references kept for provenance
```

Remote: <https://github.com/Imadiyi94/robot-shop>

## Validate (no cluster access)

```bash
bash scripts/verify-render.sh
```

The script runs `helm lint --strict` on both value sets, renders the manifests
into `dist/`, then asserts the properties that matter: zero `INSTANA_`
variables, no `LoadBalancer`, ClusterIP web Service, Ingress on
`robot-shop.local`, 8 readiness probes, 12 Deployments, load generator present,
and that flipping `instana.enabled=true` restores the agent environment.

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
