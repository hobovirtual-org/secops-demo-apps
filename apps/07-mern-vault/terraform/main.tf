# ── Random MongoDB password ───────────────────────────────────────────────
resource "random_password" "mongo_admin" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Vault: KV secret — MongoDB connection details ─────────────────────────
module "vault_secret" {
  source = "../../../_shared/vault-kv-secret"

  app_name              = local.app_name
  mount_path            = "apps/${local.app_name}"
  secret_path           = "mongodb"
  policy_name           = "${local.app_name}-mongodb-read"
  create_initial_secret = true
  secret_data = {
    # Connection string components — injected into the backend at runtime
    mongo_username = "mernapp"
    mongo_password = random_password.mongo_admin.result
    mongo_host     = "mongodb.${local.k8s_namespace}.svc.cluster.local"
    mongo_port     = "27017"
    mongo_database = "merndb"
    jwt_secret     = random_password.mongo_admin.result # rotate separately in prod
  }
}

# ── VPC ────────────────────────────────────────────────────────────────────
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  private_subnets = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  public_subnets  = [cidrsubnet(var.vpc_cidr, 8, 101), cidrsubnet(var.vpc_cidr, 8, 102)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # EKS uses these tags to discover subnets for load balancers.
  # The cluster-owned tag is applied automatically by the EKS module.
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# ── EKS ───────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = "${local.name_prefix}-cluster"
  kubernetes_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Both public and private endpoint access: nodes (private subnets) reach the
  # API via private DNS; kubectl / TFC reach it via the public endpoint.
  endpoint_public_access  = true
  endpoint_private_access = true

  eks_managed_node_groups = {
    default = {
      # AL2023 is the default for EKS 1.32; explicit avoids AMI resolution issues.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 4
      desired_size   = var.desired_node_count
    }
  }

  # Use the IAM role ARN of the HCP Terraform OIDC role (not the assumed-role
  # session ARN returned by aws_caller_identity, which EKS rejects).
  access_entries = {
    creator = {
      principal_arn = var.aws_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}

# ── Vault: Kubernetes auth ────────────────────────────────────────────────
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes/${local.app_name}"
}

resource "vault_kubernetes_auth_backend_config" "main" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = module.eks.cluster_endpoint
  kubernetes_ca_cert = base64decode(module.eks.cluster_certificate_authority_data)
}

resource "vault_kubernetes_auth_backend_role" "backend" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = local.vault_k8s_role
  bound_service_account_names      = [local.k8s_sa_name]
  bound_service_account_namespaces = [local.k8s_namespace]
  token_policies                   = [module.vault_secret.policy_name]
  token_ttl                        = 3600
}

# ── Kubernetes namespace + SA ─────────────────────────────────────────────
resource "kubernetes_namespace_v1" "app" {
  metadata { name = local.k8s_namespace }
}

resource "kubernetes_service_account_v1" "backend" {
  metadata {
    name      = local.k8s_sa_name
    namespace = local.k8s_namespace
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# ── Vault Agent Injector ───────────────────────────────────────────────────
resource "helm_release" "vault_agent_injector" {
  name             = "vault"
  namespace        = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.30.0"
  create_namespace = true

  # Give the injector pods time to schedule and become ready on a fresh cluster.
  timeout = 600
  wait    = true

  set = [
    {
      name  = "injector.enabled"
      value = "true"
    },
    {
      name  = "server.enabled"
      value = "false"
    },
    {
      name  = "injector.externalVaultAddr"
      value = var.vault_address
    },
  ]

  depends_on = [module.eks]
}

# ── MongoDB (in-cluster, StatefulSet) ─────────────────────────────────────
resource "kubernetes_config_map_v1" "mongo_init" {
  metadata {
    name      = "mongo-init"
    namespace = local.k8s_namespace
  }

  data = {
    "init.js" = <<-JS
      db = db.getSiblingDB('merndb');
      db.createUser({
        user: 'mernapp',
        pwd: process.env.MONGO_PASSWORD,
        roles: [{ role: 'readWrite', db: 'merndb' }]
      });
      db.items.insertOne({ message: 'Hello from MongoDB!', createdAt: new Date() });
    JS
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_stateful_set_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = local.k8s_namespace
  }

  spec {
    service_name = "mongodb"
    replicas     = 1

    selector {
      match_labels = { app = "mongodb" }
    }

    template {
      metadata {
        labels = { app = "mongodb" }
        annotations = {
          "vault.hashicorp.com/agent-inject"                      = "true"
          "vault.hashicorp.com/agent-inject-secret-mongodb.env"   = module.vault_secret.secret_path
          "vault.hashicorp.com/agent-inject-template-mongodb.env" = <<-TPL
            {{- with secret "${module.vault_secret.secret_path}" -}}
            export MONGO_INITDB_ROOT_PASSWORD="{{ .Data.data.mongo_password }}"
            export MONGO_INITDB_ROOT_USERNAME="{{ .Data.data.mongo_username }}"
            {{- end }}
          TPL
          "vault.hashicorp.com/role"      = local.vault_k8s_role
          "vault.hashicorp.com/namespace" = var.vault_namespace
          "vault.hashicorp.com/auth-path" = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = local.k8s_sa_name

        init_container {
          name    = "vault-env-loader"
          image   = "registry.redhat.io/ubi9/ubi-minimal:latest"
          command = ["sh", "-c", "source /vault/secrets/mongodb.env && env > /shared/mongo.env"]
          volume_mount {
            name       = "shared"
            mount_path = "/shared"
          }
        }

        container {
          name  = "mongodb"
          image = "registry.redhat.io/rhel9/mongodb-70:latest"

          port { container_port = 27017 }

          env {
            name  = "MONGO_INITDB_DATABASE"
            value = "merndb"
          }

          env_from {
            config_map_ref { name = "mongo-init" }
          }

          resources {
            requests = { cpu = "250m", memory = "256Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          volume_mount {
            name       = "mongo-data"
            mount_path = "/data/db"
          }
        }

        volume {
          name = "shared"
          empty_dir {}
        }
      }
    }

    volume_claim_template {
      metadata { name = "mongo-data" }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = { storage = "5Gi" }
        }
      }
    }
  }

  depends_on = [
    helm_release.vault_agent_injector,
    kubernetes_service_account_v1.backend,
    kubernetes_config_map_v1.mongo_init,
  ]
}

resource "kubernetes_service_v1" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = local.k8s_namespace
  }
  spec {
    selector = { app = "mongodb" }
    port {
      port        = 27017
      target_port = 27017
    }
    cluster_ip = "None" # Headless service for StatefulSet
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# ── Backend (Express/Node.js) deployment ─────────────────────────────────
resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "mern-backend"
    namespace = local.k8s_namespace
    labels    = { app = "mern-backend" }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "mern-backend" }
    }

    template {
      metadata {
        labels = { app = "mern-backend" }
        annotations = {
          "vault.hashicorp.com/agent-inject"                      = "true"
          "vault.hashicorp.com/agent-inject-secret-config.json"   = module.vault_secret.secret_path
          "vault.hashicorp.com/agent-inject-template-config.json" = <<-TPL
            {{- with secret "${module.vault_secret.secret_path}" -}}
            {{ .Data.data | toJSON }}
            {{- end }}
          TPL
          "vault.hashicorp.com/role"      = local.vault_k8s_role
          "vault.hashicorp.com/namespace" = var.vault_namespace
          "vault.hashicorp.com/auth-path" = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = local.k8s_sa_name

        container {
          name    = "mern-backend"
          image   = "registry.redhat.io/ubi9/nodejs-20-minimal:latest"
          command = ["node", "server.js"]

          working_dir = "/app"

          port { container_port = 3001 }

          env {
            name  = "SECRET_FILE"
            value = "/vault/secrets/config.json"
          }
          env {
            name  = "PORT"
            value = "3001"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.vault_agent_injector,
    kubernetes_service_account_v1.backend,
  ]
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "mern-backend"
    namespace = local.k8s_namespace
  }
  spec {
    selector = { app = "mern-backend" }
    port {
      port        = 3001
      target_port = 3001
    }
    type = "ClusterIP"
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# ── Frontend (React) deployment ───────────────────────────────────────────
resource "kubernetes_deployment_v1" "frontend" {
  metadata {
    name      = "mern-frontend"
    namespace = local.k8s_namespace
    labels    = { app = "mern-frontend" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "mern-frontend" }
    }

    template {
      metadata {
        labels = { app = "mern-frontend" }
      }

      spec {
        container {
          name    = "mern-frontend"
          image   = "registry.redhat.io/ubi9/nodejs-20-minimal:latest"
          command = ["node", "serve.js"]

          working_dir = "/app"
          port { container_port = 3000 }

          env {
            name  = "REACT_APP_API_URL"
            value = "http://mern-backend:3001"
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.app]
}

resource "kubernetes_service_v1" "frontend" {
  metadata {
    name      = "mern-frontend"
    namespace = local.k8s_namespace
  }
  spec {
    selector = { app = "mern-frontend" }
    port {
      port        = 80
      target_port = 3000
    }
    type = "LoadBalancer"
  }

  depends_on = [kubernetes_namespace_v1.app]
}
