# Capstone 2 - Stan's Robot Shop
# Namespace module: isolation guardrails for the application namespace.
#
# Everything here is namespace-scoped. No cluster-scoped objects are created,
# so this module can be applied to the inherited Kind cluster without touching
# voting-app, ingress-nginx or any other namespace.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "robot-shop"
      "app.kubernetes.io/part-of"    = "robot-shop"
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = "local"
      "capstone"                     = "2"
      # Deliberate divergence from Capstone 1, which enforces `restricted`:
      # upstream robot-shop images run as root, so `restricted` would reject
      # every pod. Baseline admits them while still blocking privileged and
      # host-namespace pods. `restricted` is audited/warned, not enforced.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  metadata {
    name      = "robot-shop-quota"
    namespace = var.namespace
  }

  spec {
    hard = {
      "requests.cpu"           = var.quota.requests_cpu
      "requests.memory"        = var.quota.requests_memory
      "limits.cpu"             = var.quota.limits_cpu
      "limits.memory"          = var.quota.limits_memory
      "pods"                   = var.quota.pods
      "services"               = var.quota.services
      "configmaps"             = var.quota.configmaps
      "secrets"                = var.quota.secrets
      "persistentvolumeclaims" = var.quota.pvc
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_limit_range_v1" "app" {
  metadata {
    name      = "robot-shop-limits"
    namespace = var.namespace
  }

  spec {
    limit {
      type = "Container"

      default = {
        cpu    = var.limit_range.default_cpu
        memory = var.limit_range.default_memory
      }

      default_request = {
        cpu    = var.limit_range.default_request_cpu
        memory = var.limit_range.default_request_mem
      }

      max = {
        cpu    = var.limit_range.max_cpu
        memory = var.limit_range.max_memory
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# ---------------------------------------------------------------------------
# Network policies: deny by default, then permit only what the application
# actually needs. Five narrow policies, no allow-all catch-alls.
# ---------------------------------------------------------------------------

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
    # No rules: every pod in the namespace is isolated in both directions.
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_network_policy_v1" "allow_dns" {
  metadata {
    name      = "allow-dns-egress"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_network_policy_v1" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = var.namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }

    egress {
      to {
        pod_selector {}
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# The shared ingress-nginx controller may reach only the storefront, on 8080.
resource "kubernetes_network_policy_v1" "allow_ingress_controller" {
  metadata {
    name      = "allow-ingress-controller"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        service = "web"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = var.ingress_namespace
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# payment is the only workload with a legitimate outbound internet call
# (https://www.paypal.com). Scoped to 443 and to public address space, so it
# cannot reach another cluster pod over HTTPS.
resource "kubernetes_network_policy_v1" "allow_payment_https" {
  metadata {
    name      = "allow-payment-egress-https"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        service = "payment"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}
