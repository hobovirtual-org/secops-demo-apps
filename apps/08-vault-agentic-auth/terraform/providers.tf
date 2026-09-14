provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      App         = "08-vault-agentic-auth"
      ManagedBy   = "Terraform"
    }
  }
}

provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace != "" ? var.vault_namespace : null
}

provider "random" {}
