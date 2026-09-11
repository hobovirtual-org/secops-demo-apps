output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster."
  value       = module.eks.cluster_certificate_authority_data
}

output "vault_secret_path" {
  description = "Vault KV path for MongoDB credentials."
  value       = module.vault_secret.secret_path
}

output "kubeconfig_command" {
  description = "Run this once after apply to configure kubectl. Requires AWS CLI v2 and aws-iam-authenticator or the aws eks get-token plugin."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "kubectl_context" {
  description = "kubectl context name created by kubeconfig_command — use with: kubectl config use-context <value>"
  value       = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${module.eks.cluster_name}"
}

output "frontend_service" {
  description = "Kubernetes service for the React frontend."
  value       = "kubectl get svc mern-frontend -n ${local.k8s_namespace}"
}

output "uptycs_tag_string" {
  description = "IBM tag string applied to the Uptycs sensor — use this for verification."
  value       = try(module.uptycs[0].tag_string, "")
}

output "uptycs_node_uuid_command" {
  description = "kubectl command to get node UUIDs for Uptycs verification tool."
  value       = try(module.uptycs[0].node_uuid_command, "")
}
