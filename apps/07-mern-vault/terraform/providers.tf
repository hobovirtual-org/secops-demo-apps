provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      App         = "07-mern-vault"
      ManagedBy   = "Terraform"
    }
  }
}

provider "vault" {
  address = var.vault_address
  # No namespace — self-managed Vault instance (root namespace).
}

# try() guards allow graceful destroy when the cluster has already been deleted:
# the provider falls back to an empty host rather than erroring on a null output.
provider "kubernetes" {
  host                   = try(module.eks.cluster_endpoint, "")
  cluster_ca_certificate = try(base64decode(module.eks.cluster_certificate_authority_data), "")

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", try(module.eks.cluster_name, "")]
  }
}

# Helm provider v3: kubernetes block uses assignment syntax (kubernetes = {...})
provider "helm" {
  kubernetes = {
    host                   = try(module.eks.cluster_endpoint, "")
    cluster_ca_certificate = try(base64decode(module.eks.cluster_certificate_authority_data), "")

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", try(module.eks.cluster_name, "")]
    }
  }
}

provider "random" {}
