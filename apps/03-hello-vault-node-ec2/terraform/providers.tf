provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      App         = "03-hello-vault-node-ec2"
      ManagedBy   = "Terraform"
    }
  }
}

provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace
}
