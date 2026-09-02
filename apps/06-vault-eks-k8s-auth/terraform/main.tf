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

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ── EKS cluster ───────────────────────────────────────────────────────────
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
      max_size       = 3
      desired_size   = var.desired_node_count
    }
  }

  enable_cluster_creator_admin_permissions = true
}

# ── Vault: KV secret ─────────────────────────────────────────────────────
module "vault_secret" {
  source = "../../../_shared/vault-kv-secret"

  app_name              = local.app_name
  mount_path            = "apps/${local.app_name}"
  secret_path           = "config"
  policy_name           = "${local.app_name}-read"
  create_initial_secret = true
  secret_data = {
    greeting    = "Hello from Vault + EKS + Node.js!"
    db_username = "appuser"
    db_password = "change-me-in-vault"
  }
}

# ── Vault: Kubernetes auth method ─────────────────────────────────────────
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes/${local.app_name}"
}

resource "vault_kubernetes_auth_backend_config" "main" {
  backend            = vault_auth_backend.kubernetes.path
  kubernetes_host    = module.eks.cluster_endpoint
  kubernetes_ca_cert = base64decode(module.eks.cluster_certificate_authority_data)
}

resource "vault_kubernetes_auth_backend_role" "app" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = local.vault_k8s_role
  bound_service_account_names      = [local.k8s_sa_name]
  bound_service_account_namespaces = [local.k8s_namespace]
  token_policies                   = [module.vault_secret.policy_name]
  token_ttl                        = 3600
}

# ── Kubernetes: namespace + service account ───────────────────────────────
resource "kubernetes_namespace" "app" {
  metadata {
    name = local.k8s_namespace
  }
}

resource "kubernetes_service_account" "app" {
  metadata {
    name      = local.k8s_sa_name
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

# ── Vault Agent Injector (Helm) ───────────────────────────────────────────
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

# ── Kubernetes: app deployment ────────────────────────────────────────────
resource "kubernetes_deployment" "app" {
  depends_on = [helm_release.vault_agent_injector]

  metadata {
    name      = "hello-vault-node"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "hello-vault-node" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "hello-vault-node" }
    }

    template {
      metadata {
        labels = { app = "hello-vault-node" }
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
        service_account_name = kubernetes_service_account.app.metadata[0].name

        container {
          name  = "hello-vault-node"
          image = "node:20-slim"

          port {
            container_port = 8080
          }

          env {
            name  = "SECRET_FILE"
            value = "/vault/secrets/config.json"
          }
          env {
            name  = "PORT"
            value = "8080"
          }

          command = ["node", "-e", <<-CMD
            const http = require('http');
            const fs   = require('fs');
            const PORT = process.env.PORT || 8080;
            const FILE = process.env.SECRET_FILE || '/vault/secrets/config.json';
            http.createServer((req, res) => {
              if (req.url === '/health') {
                res.writeHead(200, {'Content-Type':'application/json'});
                res.end(JSON.stringify({status:'healthy'}));
                return;
              }
              try {
                const data = JSON.parse(fs.readFileSync(FILE,'utf8'));
                res.writeHead(200,{'Content-Type':'application/json'});
                res.end(JSON.stringify({status:'ok',greeting:data.greeting,db_username:data.db_username}));
              } catch(e) {
                res.writeHead(500,{'Content-Type':'application/json'});
                res.end(JSON.stringify({status:'error',message:'could not read secret'}));
              }
            }).listen(PORT,'127.0.0.1',()=>console.log('Listening on '+PORT));
          CMD
          ]

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "app" {
  metadata {
    name      = "hello-vault-node"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    selector = { app = "hello-vault-node" }
    port {
      port        = 80
      target_port = 8080
    }
    type = "ClusterIP"
  }
}
