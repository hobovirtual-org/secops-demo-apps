locals {
  name_prefix = "${var.project_name}-app08-${var.environment}"

  # Vault JWT auth — jwt-github mount bootstrapped via CLI (see vault-config/main.tf)
  vault_jwt_mount   = "jwt-github"
  vault_jwt_role    = "ai-agent-role"
  vault_policy_name = "ai-agent-policy"

  # KV-v2 demo secret
  vault_kv_mount = "app08/kv"
  vault_kv_path  = "agents/app-08/config"

  # Agent Registry identity entity
  agent_entity_name = "app-08-github-actions-agent"
}
