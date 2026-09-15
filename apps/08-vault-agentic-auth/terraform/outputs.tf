output "vault_jwt_role" {
  description = "Vault JWT auth role name the agent uses to authenticate."
  value       = vault_jwt_auth_backend_role.ai_agent.role_name
}

output "vault_kv_secret_path" {
  description = "KV-v2 path the agent reads — visible in Vault audit logs."
  value       = "${vault_mount.kv.path}/data/${local.vault_kv_path}"
}

output "vault_agent_entity_name" {
  description = "Identity entity name — appears in Vault UI Agent Registry."
  value       = vault_identity_entity.ai_agent.name
}

output "vault_agent_entity_id" {
  description = "Identity entity ID."
  value       = vault_identity_entity.ai_agent.id
}

output "vault_policy_name" {
  description = "Policy attached to the agent token."
  value       = vault_policy.ai_agent.name
}
