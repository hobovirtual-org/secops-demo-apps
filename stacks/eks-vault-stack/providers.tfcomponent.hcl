required_providers {
  aws = {
    source  = "hashicorp/aws"
    version = "= 6.62.0"
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

# AWS — authenticate via OIDC (no long-lived keys)
provider "aws" "main" {
  config {
    region = var.aws_region

    assume_role_with_web_identity {
      role_arn           = var.aws_role_arn
      web_identity_token = var.identity_token
    }
  }
}

# Vault — JWT dynamic credentials via HCP Terraform (no stored token, no namespace for self-managed Vault)
provider "vault" "main" {
  config {
    address = var.vault_address
  }
}

# Kubernetes — configured from the EKS component output
provider "kubernetes" "main" {
  config {
    host                   = component.eks.cluster_endpoint
    cluster_ca_certificate = component.eks.cluster_ca_cert_b64

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", component.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# Helm — mirrors the kubernetes provider (v3: kubernetes = {...} assignment syntax)
provider "helm" "main" {
  config {
    kubernetes = {
      host                   = component.eks.cluster_endpoint
      cluster_ca_certificate = component.eks.cluster_ca_cert_b64

      exec = {
        api_version = "client.authentication.k8s.io/v1beta1"
        command     = "aws"
        args        = ["eks", "get-token", "--cluster-name", component.eks.cluster_name, "--region", var.aws_region]
      }
    }
  }
}

provider "random" "main" {
  config {}
}
