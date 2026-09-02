terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.62.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.11.0"
    }
  }

  cloud {
    organization = "crenaud-org"

    workspaces {
      name = "demo-app-01-hello-vault-python"
    }
  }
}
