variable "kubeconfig_path" {
  description = <<-EOT
    Path to the kubeconfig of the Capstone 1 Kind cluster. Read-only: this
    configuration never creates or mutates cluster infrastructure. Null falls
    back to the cross-repository default in main.tf.
  EOT
  type        = string
  default     = null
}

variable "kube_context" {
  description = "kubectl context inside the inherited kubeconfig."
  type        = string
  default     = "kind-voting-app"

  validation {
    condition     = startswith(var.kube_context, "kind-")
    error_message = "The context must be a kind-* context; Capstone 2 does not target managed clusters."
  }
}

variable "namespace" {
  description = "Dedicated namespace for Stan's Robot Shop."
  type        = string
  default     = "robot-shop"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace))
    error_message = "Namespace must be a valid RFC 1123 DNS label."
  }
}

variable "ingress_namespace" {
  description = "Namespace of the shared ingress-nginx controller installed in Capstone 1."
  type        = string
  default     = "ingress-nginx"
}

variable "quota" {
  description = <<-EOT
    Namespace quota. Sized from the rendered chart, not guessed:
    13 pods request 1300m CPU / 2056Mi and limit 2600m / 3636Mi at steady
    state. A simultaneous rollout of all 12 Deployments adds one surge pod
    each, peaking at ~2500m / 4112Mi requests and ~5000m / 7272Mi limits.
    The values below leave headroom above that peak without allowing the
    namespace to starve voting-app on a 3-node cluster.
  EOT
  type = object({
    requests_cpu    = string
    requests_memory = string
    limits_cpu      = string
    limits_memory   = string
    pods            = string
    services        = string
    configmaps      = string
    secrets         = string
    pvc             = string
  })
  default = {
    requests_cpu    = "4"
    requests_memory = "5Gi"
    limits_cpu      = "8"
    limits_memory   = "8Gi"
    pods            = "35"
    services        = "20"
    configmaps      = "20"
    secrets         = "20"
    pvc             = "5"
  }
}

variable "limit_range" {
  description = <<-EOT
    Container defaults for pods that omit resources. max must stay above the
    largest explicit upstream limit: mysql 1024Mi and shipping 1000Mi, so 2Gi.
  EOT
  type = object({
    default_cpu         = string
    default_memory      = string
    default_request_cpu = string
    default_request_mem = string
    max_cpu             = string
    max_memory          = string
  })
  default = {
    default_cpu         = "500m"
    default_memory      = "512Mi"
    default_request_cpu = "100m"
    default_request_mem = "128Mi"
    max_cpu             = "2"
    max_memory          = "2Gi"
  }
}
