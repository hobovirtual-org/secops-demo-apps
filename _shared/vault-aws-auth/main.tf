# ---------------------------------------------------------------------------
# Vault AWS auth method + per-app role
#
# The AWS auth backend is a singleton — it is enabled once at the Vault level
# by demo-apps-vault-config (or manually during bootstrap).  Each app workspace
# uses this module only to create its own IAM role; it references the
# pre-existing backend via a data source rather than trying to re-create it.
# ---------------------------------------------------------------------------

data "vault_auth_backend" "aws" {
  path = var.auth_path
}

resource "vault_aws_auth_backend_role" "app" {
  backend   = data.vault_auth_backend.aws.path
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
