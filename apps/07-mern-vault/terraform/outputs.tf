output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "vault_secret_path" {
  description = "Vault KV path for MongoDB credentials."
  value       = module.vault_secret.secret_path
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "frontend_service" {
  description = "Kubernetes service for the React frontend."
  value       = "kubectl get svc mern-frontend -n ${local.k8s_namespace}"
}

output "uptycs_tag_string" {
  description = "IBM tag string applied to the Uptycs sensor — use this for verification."
  value       = module.uptycs.tag_string
}

output "uptycs_node_uuid_command" {
  description = "kubectl command to get node UUIDs for Uptycs verification tool."
  value       = module.uptycs.node_uuid_command
}
