terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 3.2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "= 3.9.0"
    }
  }

  cloud {
    organization = "crenaud-org"
    workspaces {
      name = "demo-app-07-mern-vault"
    }
  }
}
