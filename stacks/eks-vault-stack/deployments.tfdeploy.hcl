# ---------------------------------------------------------------------------
# HCP Terraform Stack deployments
# ---------------------------------------------------------------------------

# Workload identity token — short-lived OIDC JWT issued per run
identity_token "aws" {
  audience = ["aws.workload.identity"]
}

# ── Dev deployment ────────────────────────────────────────────────────────
deployment "dev" {
  inputs = {
    project_name       = "demo"
    environment        = "dev"
    aws_region         = "us-east-1"
    vault_address      = "https://vault.christian-renaud.sbx.hashidemos.io"
    vault_namespace    = ""
    aws_role_arn       = "arn:aws:iam::REPLACE_WITH_YOUR_ACCOUNT_ID:role/hcp-terraform-oidc-demo"
    identity_token     = identity_token.aws.jwt
    node_instance_type = "t3.small"
    desired_node_count = 2
  }
}

# ── Prod deployment (example — add when ready) ────────────────────────────
# deployment "prod" {
#   inputs = {
#     project_name       = "demo"
#     environment        = "prod"
#     aws_region         = "us-east-1"
#     vault_address      = "https://vault.christian-renaud.sbx.hashidemos.io"
#     vault_namespace    = ""
#     aws_role_arn       = "arn:aws:iam::REPLACE_WITH_YOUR_ACCOUNT_ID:role/hcp-terraform-oidc-demo"
#     identity_token     = identity_token.aws.jwt
#     node_instance_type = "t3.medium"
#     desired_node_count = 3
#   }
# }
