output "name" {
  description = "Created namespace."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "quota_hard" {
  description = "Effective ResourceQuota ceilings."
  value       = kubernetes_resource_quota_v1.app.spec[0].hard
}

output "network_policies" {
  description = "Network policies that form the default-deny baseline."
  value = [
    kubernetes_network_policy_v1.default_deny.metadata[0].name,
    kubernetes_network_policy_v1.allow_dns.metadata[0].name,
    kubernetes_network_policy_v1.allow_same_namespace.metadata[0].name,
    kubernetes_network_policy_v1.allow_ingress_controller.metadata[0].name,
    kubernetes_network_policy_v1.allow_payment_https.metadata[0].name,
  ]
}
