# Capstone 2 - Stan's Robot Shop
# Root Terraform configuration
#
# Responsibility split:
#   Terraform -> namespace guardrails only (Namespace, ResourceQuota,
#                LimitRange, default-deny NetworkPolicies)
#   Helm      -> every workload (see helm/robot-shop)
#
# This configuration CONSUMES the Kind cluster built in Capstone 1. It never
# creates a cluster, node pool, or any other infrastructure: the only cluster
# contact is reading the existing kubeconfig by path.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }

  backend "local" {
    path = "./terraform.tfstate"
  }
}

provider "kubernetes" {
  config_path    = local.kubeconfig_path
  config_context = var.kube_context
}

locals {
  # Default to the Capstone 1 kubeconfig across the repository boundary. An
  # explicit -var or KUBECONFIG override always wins.
  kubeconfig_path = coalesce(
    var.kubeconfig_path,
    "${path.module}/../../example-voting-app/terraform/kubeconfig-voting-app",
  )
}

# =========================================================================
# MODULE: namespace, quota, limit range and default-deny network policies
# =========================================================================

module "namespace" {
  source = "./modules/namespace"

  namespace         = var.namespace
  ingress_namespace = var.ingress_namespace

  quota       = var.quota
  limit_range = var.limit_range
}
