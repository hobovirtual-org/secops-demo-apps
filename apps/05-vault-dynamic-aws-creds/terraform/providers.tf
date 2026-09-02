provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      App         = "05-vault-dynamic-aws-creds"
      ManagedBy   = "Terraform"
    }
  }
}

provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace
}
