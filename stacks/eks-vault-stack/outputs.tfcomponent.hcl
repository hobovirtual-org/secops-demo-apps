output "cluster_name" {
  type        = string
  description = "EKS cluster name."
  value       = component.eks.cluster_name
}

output "cluster_endpoint" {
  type        = string
  description = "EKS API server endpoint."
  value       = component.eks.cluster_endpoint
}

output "vault_secret_path" {
  type        = string
  description = "Full Vault KV path."
  value       = component.vault_secret.secret_path
}
