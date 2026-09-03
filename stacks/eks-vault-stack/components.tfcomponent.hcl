# ---------------------------------------------------------------------------
# Stack components
#
# Component dependency graph:
#   vpc ──▶ eks ──▶ vault-k8s-auth ──▶ app
# ---------------------------------------------------------------------------

locals {
  name_prefix = "${var.project_name}-eks-${var.environment}"
  app_name    = "eks-vault-stack"
}

# ── VPC ────────────────────────────────────────────────────────────────────
component "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  inputs = {
    name = "${local.name_prefix}-vpc"
    cidr = "10.40.0.0/16"

    azs             = ["${var.aws_region}a", "${var.aws_region}b"]
    private_subnets = ["10.40.1.0/24", "10.40.2.0/24"]
    public_subnets  = ["10.40.101.0/24", "10.40.102.0/24"]

    enable_nat_gateway   = true
    single_nat_gateway   = true
    enable_dns_hostnames = true

    public_subnet_tags  = { "kubernetes.io/role/elb"          = "1" }
    private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform Stacks"
    }
  }

  providers = {
    aws = provider.aws.main
  }
}

# ── EKS ───────────────────────────────────────────────────────────────────
component "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  inputs = {
    name               = "${local.name_prefix}-cluster"
    kubernetes_version = "1.32"

    vpc_id     = component.vpc.vpc_id
    subnet_ids = component.vpc.private_subnets

    endpoint_public_access = true

    eks_managed_node_groups = {
      default = {
        instance_types = [var.node_instance_type]
        min_size       = 1
        max_size       = 4
        desired_size   = var.desired_node_count
      }
    }

    # Grant the OIDC IAM role (used by HCP Terraform / Stacks) cluster-admin access.
    access_entries = {
      deployer = {
        principal_arn = var.aws_role_arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    }

    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform Stacks"
    }
  }

  providers = {
    aws = provider.aws.main
  }
}

# ── Vault: KV secret ─────────────────────────────────────────────────────
component "vault_secret" {
  source = "../../_shared/vault-kv-secret"

  inputs = {
    app_name              = local.app_name
    mount_path            = "apps/${local.app_name}"
    secret_path           = "config"
    policy_name           = "${local.app_name}-read"
    create_initial_secret = true
    secret_data = {
      greeting    = "Hello from Vault Stacks + EKS!"
      db_username = "appuser"
      db_password = "change-me-in-vault"
    }
  }

  providers = {
    vault = provider.vault.main
  }
}

# ── Vault: Kubernetes auth ────────────────────────────────────────────────
component "vault_k8s_auth" {
  source = "./modules/vault-k8s-auth"

  inputs = {
    cluster_endpoint    = component.eks.cluster_endpoint
    cluster_ca_cert_b64 = component.eks.cluster_certificate_authority_data
    vault_k8s_role      = local.app_name
    k8s_namespace       = local.app_name
    k8s_sa_name         = local.app_name
    token_policies      = [component.vault_secret.policy_name]
    vault_namespace     = var.vault_namespace
    app_name            = local.app_name
  }

  providers = {
    vault = provider.vault.main
  }
}

# ── Application workload ──────────────────────────────────────────────────
component "app" {
  source = "./modules/app-workload"

  inputs = {
    k8s_namespace       = local.app_name
    k8s_sa_name         = local.app_name
    vault_role          = local.app_name
    vault_namespace     = var.vault_namespace
    vault_auth_path     = component.vault_k8s_auth.auth_path
    vault_secret_path   = component.vault_secret.secret_path
    name_prefix         = local.name_prefix
  }

  providers = {
    kubernetes = provider.kubernetes.main
    helm       = provider.helm.main
  }
}
