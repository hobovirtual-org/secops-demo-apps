output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "vault_k8s_auth_path" {
  description = "Vault Kubernetes auth mount path."
  value       = vault_auth_backend.kubernetes.path
}

output "vault_secret_path" {
  description = "Full Vault KV path."
  value       = module.vault_secret.secret_path
}

output "kubeconfig_command" {
  description = "Command to update local kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
