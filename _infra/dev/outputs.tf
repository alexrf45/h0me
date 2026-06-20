output "talos_config" {
  value     = module.dev.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = module.dev.kubeconfig
  sensitive = true
}

output "machineconfig" {
  value     = module.dev.machineconfig
  sensitive = true
}

output "kubernetes_host" {
  value     = module.dev.kubernetes_host
  sensitive = true
}

output "kubernetes_client_certificate" {
  value     = module.dev.kubernetes_client_certificate
  sensitive = true
}

output "kubernetes_client_key" {
  value     = module.dev.kubernetes_client_key
  sensitive = true
}

output "kubernetes_cluster_ca_certificate" {
  value     = module.dev.kubernetes_cluster_ca_certificate
  sensitive = true
}


output "post_deployment_instructions" {
  value       = module.dev.post_deployment_instructions
  description = "Post-deployment instructions"
}
