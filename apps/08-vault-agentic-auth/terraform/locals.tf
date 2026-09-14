data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  app_name    = "vault-agentic-auth"
  name_prefix = "${var.project_name}-app08-${var.environment}"

  # ECS OIDC issuer used to configure the Vault JWT auth method.
  # ECS task identity tokens are issued by the regional STS OIDC endpoint.
  ecs_oidc_issuer = "https://oidc.eks.${var.aws_region}.amazonaws.com"

  # Vault JWT auth path and role
  vault_jwt_path = "auth/jwt"
  vault_jwt_role = "ai-agent-role"

  # Vault secret paths
  vault_kv_mount      = "secret"
  vault_kv_agent_path = "agents/app-08/watsonx"
  vault_db_mount      = "database"
  vault_db_role       = "agent-postgres-role"
  vault_policy_name   = "ai-agent-policy"

  # Agent Registry identity entity metadata
  agent_entity_name = "app-08-watsonx-agent"

  # Postgres container config (runs as a sidecar on ECS — no RDS cost)
  postgres_db   = "agentdb"
  postgres_port = 5432

  # Container image — built from app/agent/Dockerfile and pushed to ECR
  agent_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name_prefix}-agent:latest"
}
