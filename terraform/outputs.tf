output "namespace" {
  description = "Namespace that holds Stan's Robot Shop."
  value       = module.namespace.name
}

output "quota_hard" {
  description = "Effective quota ceilings for the namespace."
  value       = module.namespace.quota_hard
}

output "network_policies" {
  description = "Default-deny baseline policies applied to the namespace."
  value       = module.namespace.network_policies
}

output "helm_install_command" {
  description = "Phase 1 install command once the namespace exists."
  value = join(" ", [
    "helm upgrade --install robot-shop helm/robot-shop",
    "--namespace ${module.namespace.name}",
    "-f helm/robot-shop/values-phase1.yaml",
  ])
}
