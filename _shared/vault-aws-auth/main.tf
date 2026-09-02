# ---------------------------------------------------------------------------
# Vault AWS auth method + per-app role
#
# This module:
#   1. Enables the AWS auth method at the given path (idempotent).
#   2. Creates a named role that binds an EC2 IAM instance profile ARN
#      (or IAM role ARN for IAM-type auth) to a Vault policy.
# ---------------------------------------------------------------------------

resource "vault_auth_backend" "aws" {
  type = "aws"
  path = var.auth_path

  description = "AWS auth method for ${var.app_name}"
}

resource "vault_aws_auth_backend_client" "main" {
  backend = vault_auth_backend.aws.path

  # Vault will use the Vault server's own IAM role to call the AWS STS API.
  # Leave access_key / secret_key empty so Vault uses its instance profile.
}

resource "vault_aws_auth_backend_role" "app" {
  backend   = vault_auth_backend.aws.path
  role      = var.role_name
  auth_type = var.auth_type

  # IAM-type: bind by IAM role ARN
  bound_iam_principal_arns = var.auth_type == "iam" ? var.bound_iam_principal_arns : []

  # EC2-type: bind by IAM instance profile ARN
  bound_iam_instance_profile_arns = var.auth_type == "ec2" ? var.bound_iam_instance_profile_arns : []

  token_policies = var.token_policies
  token_ttl      = var.token_ttl
  token_max_ttl  = var.token_max_ttl
}
