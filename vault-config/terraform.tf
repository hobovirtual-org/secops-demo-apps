terraform {
  required_version = ">= 1.9.0"

  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }

  cloud {
    organization = "crenaud-org"

    workspaces {
      name = "demo-apps-vault-config"
    }
  }
}
