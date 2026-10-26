variable "namespace" {
  description = "Namespace to create and guard."
  type        = string
}

variable "ingress_namespace" {
  description = "Namespace of the shared ingress-nginx controller."
  type        = string
}

variable "quota" {
  description = "ResourceQuota ceilings for the namespace."
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
}

variable "limit_range" {
  description = "Container LimitRange defaults and ceilings."
  type = object({
    default_cpu         = string
    default_memory      = string
    default_request_cpu = string
    default_request_mem = string
    max_cpu             = string
    max_memory          = string
  })
}
