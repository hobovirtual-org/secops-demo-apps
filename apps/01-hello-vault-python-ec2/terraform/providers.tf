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
# TFC_VAULT_PROVIDER_AUTH=true causes HCP Terraform to exchange a signed JWT
# for a short-lived Vault token before the run starts. No stored token anywhere.
# Self-managed Vault — no namespace (root).
provider "vault" {
  address = var.vault_address
  # No namespace — self-managed Vault instance uses root namespace.
  # No token — injected automatically via TFC_VAULT_PROVIDER_AUTH JWT exchange.
}
