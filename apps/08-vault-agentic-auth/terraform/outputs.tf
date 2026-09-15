output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name for the agent."
  value       = aws_ecs_service.agent.name
}

output "ecr_repository_url" {
  description = "ECR repository URL — push the agent image here before running the ECS service."
  value       = aws_ecr_repository.agent.repository_url
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for agent and Postgres container logs."
  value       = aws_cloudwatch_log_group.agent.name
}

output "vault_jwt_auth_path" {
  description = "Vault JWT auth method mount path."
  value       = local.vault_jwt_path
}

output "vault_jwt_role" {
  description = "Vault JWT auth role name used by the ECS agent."
  value       = vault_jwt_auth_backend_role.ecs_agent.role_name
}

output "vault_policy_name" {
  description = "Vault policy attached to the agent."
  value       = vault_policy.ai_agent.name
}

output "vault_db_role" {
  description = "Vault Database secrets engine role for dynamic Postgres credentials."
  value       = vault_database_secret_backend_role.agent_postgres.name
}

output "vault_agent_entity_id" {
  description = "Vault Identity entity ID for the Agent Registry entry."
  value       = vault_identity_entity.ai_agent.id
}

output "vault_agent_entity_name" {
  description = "Vault Identity entity name — visible in the Vault UI Agent Registry."
  value       = vault_identity_entity.ai_agent.name
}

output "ecs_task_role_arn" {
  description = "IAM role ARN used by the ECS task — bound as the JWT sub claim in Vault."
  value       = aws_iam_role.ecs_task_role.arn
}

output "postgres_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Postgres admin password."
  value       = aws_secretsmanager_secret.postgres_password.arn
}

output "docker_push_commands" {
  description = "Commands to build and push the agent container image to ECR."
  value       = <<-EOT
    aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com
    docker build -t ${aws_ecr_repository.agent.repository_url}:latest apps/08-vault-agentic-auth/app/agent/
    docker push ${aws_ecr_repository.agent.repository_url}:latest
  EOT
}
