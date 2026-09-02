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
