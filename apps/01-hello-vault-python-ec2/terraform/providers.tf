provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      App         = "01-hello-vault-python-ec2"
      ManagedBy   = "Terraform"
    }
  }
}

# Vault provider — authenticates via HCP Terraform JWT dynamic credentials.
# When TFC_VAULT_PROVIDER_AUTH=true, HCP Terraform exchanges a signed JWT for
# a short-lived Vault token and injects it as VAULT_TOKEN automatically.
# No token is ever stored. address and namespace come from TFC_VAULT_ADDR /
# TFC_VAULT_NAMESPACE injected by the platform-control-workspace variable set.
provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace
  # token is NOT set here — injected via VAULT_TOKEN env var by HCP Terraform
}
