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

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# ── EKS ───────────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.36"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = "1.32"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 4
      desired_size   = var.desired_node_count
    }
  }

  enable_cluster_creator_admin_permissions = true
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
resource "kubernetes_namespace" "app" {
  metadata { name = local.k8s_namespace }
}

resource "kubernetes_service_account" "backend" {
  metadata {
    name      = local.k8s_sa_name
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

# ── Vault Agent Injector ───────────────────────────────────────────────────
resource "helm_release" "vault_agent_injector" {
  name       = "vault"
  namespace  = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.30.0"

  create_namespace = true

  set {
    name  = "injector.enabled"
    value = "true"
  }
  set {
    name  = "server.enabled"
    value = "false"
  }
  set {
    name  = "injector.externalVaultAddr"
    value = var.vault_address
  }
}

# ── MongoDB (in-cluster, StatefulSet) ─────────────────────────────────────
resource "kubernetes_config_map" "mongo_init" {
  metadata {
    name      = "mongo-init"
    namespace = kubernetes_namespace.app.metadata[0].name
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
}

resource "kubernetes_stateful_set" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace.app.metadata[0].name
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
          "vault.hashicorp.com/agent-inject-secret-mongodb.env"   = "${module.vault_secret.secret_path}"
          "vault.hashicorp.com/agent-inject-template-mongodb.env" = <<-TPL
            {{- with secret "${module.vault_secret.secret_path}" -}}
            export MONGO_INITDB_ROOT_PASSWORD="{{ .Data.data.mongo_password }}"
            export MONGO_INITDB_ROOT_USERNAME="{{ .Data.data.mongo_username }}"
            {{- end }}
          TPL
          "vault.hashicorp.com/role"                              = local.vault_k8s_role
          "vault.hashicorp.com/namespace"                         = var.vault_namespace
          "vault.hashicorp.com/auth-path"                         = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.backend.metadata[0].name

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
}

resource "kubernetes_service" "mongodb" {
  metadata {
    name      = "mongodb"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "mongodb" }
    port {
      port        = 27017
      target_port = 27017
    }
    cluster_ip = "None" # Headless service for StatefulSet
  }
}

# ── Backend (Express/Node.js) deployment ─────────────────────────────────
resource "kubernetes_deployment" "backend" {
  depends_on = [helm_release.vault_agent_injector]

  metadata {
    name      = "mern-backend"
    namespace = kubernetes_namespace.app.metadata[0].name
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
          "vault.hashicorp.com/agent-inject-secret-config.json"   = "${module.vault_secret.secret_path}"
          "vault.hashicorp.com/agent-inject-template-config.json" = <<-TPL
            {{- with secret "${module.vault_secret.secret_path}" -}}
            {{ .Data.data | toJSON }}
            {{- end }}
          TPL
          "vault.hashicorp.com/role"                              = local.vault_k8s_role
          "vault.hashicorp.com/namespace"                         = var.vault_namespace
          "vault.hashicorp.com/auth-path"                         = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.backend.metadata[0].name

        container {
          name    = "mern-backend"
          image   = "node:20-slim"
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
}

resource "kubernetes_service" "backend" {
  metadata {
    name      = "mern-backend"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "mern-backend" }
    port {
      port        = 3001
      target_port = 3001
    }
    type = "ClusterIP"
  }
}

# ── Frontend (React) deployment ───────────────────────────────────────────
resource "kubernetes_deployment" "frontend" {
  metadata {
    name      = "mern-frontend"
    namespace = kubernetes_namespace.app.metadata[0].name
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
          image   = "node:20-slim"
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
}

resource "kubernetes_service" "frontend" {
  metadata {
    name      = "mern-frontend"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "mern-frontend" }
    port {
      port        = 80
      target_port = 3000
    }
    type = "LoadBalancer"
  }
}
