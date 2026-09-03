output "auth_path" {
  description = "Mount path of the AWS auth backend."
  value       = data.vault_auth_backend.aws.path
}

output "role_name" {
  description = "Name of the Vault AWS auth role."
  value       = vault_aws_auth_backend_role.app.role
}

output "role_id" {
  description = "Vault internal ID of the AWS auth role."
  value       = vault_aws_auth_backend_role.app.id
}
