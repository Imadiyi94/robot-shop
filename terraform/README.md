# Terraform — namespace guardrails

Creates **only** namespace-scoped objects in the Kind cluster inherited from
Capstone 1:

| Object | Purpose |
| --- | --- |
| Namespace `robot-shop` | isolation from `voting-app`, PSA `baseline` |
| ResourceQuota | ceilings sized to the rollout peak, not steady state |
| LimitRange | defaults for pods that omit resources; `max` 2 CPU / 2Gi |
| 5 NetworkPolicies | default-deny, DNS, intra-namespace, ingress-controller, payment HTTPS |

No cluster, node, network or cloud resource is created here. The kubeconfig is
read from `../../example-voting-app/terraform/kubeconfig-voting-app` by default.

## Usage

```bash
cd terraform
terraform init
terraform validate
terraform plan -out=../dist/phase1.tfplan
# Step 4/5, once approved:
terraform apply ../dist/phase1.tfplan
```

Workloads are **not** managed here. They are a single Helm release
(`helm/robot-shop`), so a rollback never fights Terraform state.

## Offline provider install

`registry.terraform.io` does not resolve from this workstation, so `terraform
init` fails with `no such host`. Provider `2.38.0` is already present in
Capstone 1's cache, which is laid out exactly like a `filesystem_mirror`:

```hcl
# C:\Users\HP\AppData\Local\Temp\opencode\tf-cli-offline.tfrc
provider_installation {
  filesystem_mirror {
    path    = "C:/Users/HP/OneDrive/Desktop/my_devops_capstones/example-voting-app/terraform/.terraform/providers"
    include = ["registry.terraform.io/hashicorp/kubernetes"]
  }
}
```

```powershell
$env:TF_CLI_CONFIG_FILE = "C:\Users\HP\AppData\Local\Temp\opencode\tf-cli-offline.tfrc"
terraform init
```

CI does not need this: with registry access, `terraform init` installs the
provider from the lock file.

## State

Local backend (`./terraform.tfstate`), git-ignored along with `*.tfplan`.
`terraform/.terraform.lock.hcl` **is** committed — it pins provider checksums.

## Quota sizing

Sized to the simultaneous-rollout peak because `helm upgrade` rolls all 12
Deployments at once: 13 steady pods use 1.3 CPU / 2.0Gi requests; the peak with
12 surge pods is ~2.5 CPU / 4.1Gi. Quota is 4 CPU / 5Gi requests and 8 CPU /
8Gi limits.

## NetworkPolicy caveat

The cluster's CNI is **kindnetd**, which ignores NetworkPolicy. The policies are
valid and create cleanly but are not enforced at runtime. Installing Calico or
Cilium would make them effective — and would also blocked kubelet probes and
Prometheus scrapes unless matching allow-policies are added first. See
`../docs/IMPLEMENTATION_PLAN.md` §10.
