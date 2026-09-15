data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  app_name    = "vault-agentic-auth"
  name_prefix = "${var.project_name}-app08-${var.environment}"

  # ECS OIDC issuer used to configure the Vault JWT auth method.
  # ECS task identity tokens are issued by the regional STS OIDC endpoint.
  ecs_oidc_issuer = "https://oidc.eks.${var.aws_region}.amazonaws.com"

  # Vault JWT auth path and role — auth/jwt is a shared mount managed by vault-config
  vault_jwt_path = "jwt"
  vault_jwt_role = "ai-agent-role"

  # Vault secret paths — KV mount removed (Bedrock uses IAM, no API key in Vault)
  # Use an app-scoped mount path to avoid colliding with any pre-existing database/ mount
  vault_db_mount    = "app08/database"
  vault_db_role     = "agent-postgres-role"
  vault_policy_name = "ai-agent-policy"

  # Agent Registry identity entity metadata
  agent_entity_name = "app-08-bedrock-agent"

  # Bedrock model — Claude 3 Haiku (fast, cost-effective for demo)
  bedrock_model_id = "anthropic.claude-3-haiku-20240307-v1:0"

  # Postgres container config (runs as a sidecar on ECS — no RDS cost)
  postgres_db   = "agentdb"
  postgres_port = 5432

  # Container image — built from app/agent/Dockerfile and pushed to ECR
  agent_image = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${local.name_prefix}-agent:latest"
}
