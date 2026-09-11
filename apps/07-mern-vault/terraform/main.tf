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

  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = true

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
  kubernetes_version = "1.36"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  # Both public and private endpoint access: nodes (private subnets) reach the
  # API via private DNS; kubectl / TFC reach it via the public endpoint.
  endpoint_public_access  = true
  endpoint_private_access = true

  # Allow the EKS control plane to reach the Vault Agent Injector webhook on port 8080
  node_security_group_additional_rules = {
    ingress_vault_injector = {
      description                   = "Allow EKS control plane to communicate with Vault Agent Injector webhook"
      protocol                      = "tcp"
      from_port                     = 8080
      to_port                       = 8080
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    default = {
      # AL2023 is the default for EKS 1.32; explicit avoids AMI resolution issues.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]
      min_size       = 1
      max_size       = 4
      desired_size   = var.desired_node_count

      # AL2023 nodes run the aws-node CNI DaemonSet inside a container, which
      # makes IMDS calls one hop away from the host. The module default of 1
      # blocks those calls and causes NodeCreationFailure / Unhealthy nodes.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required" # IMDSv2 enforced
        http_put_response_hop_limit = 2
      }
    }
  }

  # Grant the Terraform caller (HCP Terraform OIDC role) cluster admin
  # automatically — avoids having to pass its ARN as a variable.
  enable_cluster_creator_admin_permissions = true

  # Additional developer roles for kubectl access — passed in via
  # var.developer_role_arns so no ARNs are hardcoded here.
  access_entries = {
    for arn in var.developer_role_arns : arn => {
      principal_arn = arn
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
  backend                = vault_auth_backend.kubernetes.path
  kubernetes_host        = module.eks.cluster_endpoint
  kubernetes_ca_cert     = base64decode(module.eks.cluster_certificate_authority_data)
  issuer                 = module.eks.cluster_oidc_issuer_url
  disable_iss_validation = false
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

  depends_on = [module.eks.eks_managed_node_groups]
}

resource "kubernetes_service_account_v1" "backend" {
  metadata {
    name      = local.k8s_sa_name
    namespace = local.k8s_namespace
  }

  depends_on = [kubernetes_namespace_v1.app]
}

# Grant the ServiceAccount permissions to validate tokens via the TokenReview API
resource "kubernetes_cluster_role_binding_v1" "vault_auth_delegator" {
  metadata {
    name = "vault-token-review-binding-${local.app_name}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.k8s_sa_name
    namespace = local.k8s_namespace
  }

  depends_on = [kubernetes_service_account_v1.backend]
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
    {
      name  = "injector.hostNetwork"
      value = "true"
    },
  ]

  # Wait for node group to be ACTIVE before scheduling any pods.
  # module.eks completes when the control plane is ready, but nodes may still
  # be joining — depending on eks_managed_node_groups ensures at least one
  # node group has reached ACTIVE before the first helm release is attempted.
  depends_on = [module.eks.eks_managed_node_groups]
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
          "vault.hashicorp.com/role"                              = local.vault_k8s_role
          "vault.hashicorp.com/namespace"                         = var.vault_namespace
          "vault.hashicorp.com/auth-path"                         = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = local.k8s_sa_name

        container {
          name    = "mongodb"
          image   = "registry.access.redhat.com/ubi9/ubi-minimal:latest"
          command = ["sh", "-c", "echo 'MongoDB stub running' && sleep infinity"]

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
          name = "mongo-data"
          empty_dir {}
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
          "vault.hashicorp.com/role"                              = local.vault_k8s_role
          "vault.hashicorp.com/namespace"                         = var.vault_namespace
          "vault.hashicorp.com/auth-path"                         = "auth/kubernetes/${local.app_name}"
        }
      }

      spec {
        service_account_name = local.k8s_sa_name

        container {
          name  = "mern-backend"
          image = "registry.access.redhat.com/ubi9/nodejs-20-minimal:latest"
          command = ["node", "-e", <<-JS
            const http = require('http');
            const fs   = require('fs');
            const PORT = process.env.PORT || 3001;
            const FILE = process.env.SECRET_FILE || '/vault/secrets/config.json';
            
            let items = [
              { _id: '1', message: 'Hello from Vault-secured MERN stack!', createdAt: new Date().toISOString() }
            ];

            const server = http.createServer((req, res) => {
              res.setHeader('Access-Control-Allow-Origin', '*');
              res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
              res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

              if (req.method === 'OPTIONS') {
                res.writeHead(204);
                res.end();
                return;
              }

              if (req.url === '/health') {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'healthy' }));
                return;
              }

              if (req.url === '/api/vault-status' && req.method === 'GET') {
                try {
                  const secrets = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({
                    auth_method: 'Kubernetes (JWT ServiceAccount)',
                    secret_path: 'apps/mern-vault/data/mongodb',
                    injected_file: FILE,
                    status: 'Connected & Secrets Injected by Vault Agent Sidecar',
                    mongo_host: secrets.mongo_host || 'mongodb.mern-vault.svc.cluster.local',
                    mongo_database: secrets.mongo_database || 'merndb',
                    mongo_user: secrets.mongo_username || 'mernapp',
                    jwt_secret_configured: !!secrets.jwt_secret
                  }));
                } catch (e) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Vault secret error: ' + e.message }));
                }
                return;
              }

              if (req.url === '/api/items' && req.method === 'GET') {
                try {
                  const secrets = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify(items));
                } catch (e) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Vault secret not available yet: ' + e.message }));
                }
                return;
              }

              if (req.url === '/api/items' && req.method === 'POST') {
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                  try {
                    const parsed = JSON.parse(body);
                    const item = { _id: Date.now().toString(), message: parsed.message || 'No message', createdAt: new Date().toISOString() };
                    items.unshift(item);
                    res.writeHead(201, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify(item));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Invalid JSON' }));
                  }
                });
                return;
              }

              res.writeHead(404, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Not found' }));
            });

            server.listen(PORT, '0.0.0.0', () => console.log('MERN Backend listening on port ' + PORT));
          JS
          ]

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
          name  = "mern-frontend"
          image = "registry.access.redhat.com/ubi9/nodejs-20-minimal:latest"
          command = ["node", "-e", <<-JS
            const http = require('http');
            const PORT = process.env.PORT || 3000;

            const html = `<!DOCTYPE html>
            <html>
            <head>
              <title>MERN + Vault Security Demo</title>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              <style>
                body { font-family: -apple-system, system-ui, sans-serif; margin: 30px auto; max-width: 720px; padding: 0 16px; color: #1f2328; background: #fafbfc; }
                .card { background: #fff; border: 1px solid #e1e4e8; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
                h1 { margin: 0 0 8px; font-size: 22px; color: #24292e; }
                h2 { margin: 0 0 12px; font-size: 16px; color: #24292e; border-bottom: 1px solid #eaecef; padding-bottom: 6px; }
                p { color: #57606a; font-size: 14px; margin: 0 0 16px; }
                .flow-step { display: flex; align-items: center; justify-content: space-between; padding: 8px 12px; background: #f6f8fa; border-radius: 6px; margin-bottom: 8px; font-size: 13px; }
                .badge { padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 600; }
                .badge-green { background: #dafbe1; color: #1a7f37; }
                .badge-blue { background: #ddf4ff; color: #0969da; }
                .badge-purple { background: #fbefff; color: #8250df; }
                form { display: flex; gap: 8px; margin-bottom: 16px; }
                input { flex: 1; padding: 8px 12px; border-radius: 6px; border: 1px solid #d0d7de; font-size: 14px; }
                button { padding: 8px 18px; background: #1f883d; color: #fff; border: none; border-radius: 6px; font-weight: 600; cursor: pointer; }
                ul { list-style: none; padding: 0; margin: 0; }
                li { padding: 10px 12px; border-bottom: 1px solid #e1e4e8; font-size: 14px; display: flex; justify-content: space-between; align-items: center; }
                .meta { color: #57606a; font-size: 12px; }
                pre { background: #f6f8fa; padding: 12px; border-radius: 6px; font-size: 12px; overflow-x: auto; margin: 0; border: 1px solid #e1e4e8; }
              </style>
            </head>
            <body>
              <div class="card">
                <h1>MERN + Vault Security Flow</h1>
                <p>Zero static tokens, dynamic Kubernetes ServiceAccount authentication & sidecar secret rendering.</p>
                
                <h2>Interactive Architecture & Communication Flow</h2>
                <div style="background:#0f172a; border-radius:8px; padding:12px; margin-bottom:16px; overflow-x:auto;">
                  <svg viewBox="0 0 760 300" width="100%" height="240" style="min-width:600px; display:block; margin:auto;">
                    <defs>
                      <marker id="arr-b" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                        <path d="M 0 1 L 8 5 L 0 9 z" fill="#38bdf8"/>
                      </marker>
                      <marker id="arr-g" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                        <path d="M 0 1 L 8 5 L 0 9 z" fill="#4ade80"/>
                      </marker>
                      <marker id="arr-p" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                        <path d="M 0 1 L 8 5 L 0 9 z" fill="#c084fc"/>
                      </marker>
                    </defs>

                    <!-- User Box -->
                    <rect x="20" y="20" width="120" height="60" rx="6" fill="#1e293b" stroke="#64748b" stroke-width="1.5"/>
                    <text x="80" y="44" fill="#f8fafc" font-size="12" font-weight="700" text-anchor="middle">Browser / User</text>
                    <text x="80" y="62" fill="#94a3b8" font-size="10" text-anchor="middle">Port 80 (ELB)</text>

                    <!-- Frontend Pod -->
                    <rect x="20" y="140" width="150" height="130" rx="8" fill="#1e293b" stroke="#0284c7" stroke-width="1.5"/>
                    <text x="95" y="162" fill="#38bdf8" font-size="12" font-weight="700" text-anchor="middle">mern-frontend Pod</text>
                    <rect x="30" y="175" width="130" height="40" rx="4" fill="#0f172a" stroke="#334155"/>
                    <text x="95" y="193" fill="#cbd5e1" font-size="10" text-anchor="middle">React 19 / Node.js</text>
                    <text x="95" y="207" fill="#64748b" font-size="9" text-anchor="middle">Proxy API to backend</text>
                    <text x="95" y="245" fill="#f59e0b" font-size="10" text-anchor="middle">ClusterIP :3000</text>

                    <!-- Backend Pod -->
                    <rect x="230" y="70" width="230" height="200" rx="8" fill="#1e293b" stroke="#3b82f6" stroke-width="1.5"/>
                    <text x="345" y="92" fill="#60a5fa" font-size="12" font-weight="700" text-anchor="middle">mern-backend Pod (2/2)</text>
                    
                    <!-- App Container -->
                    <rect x="240" y="105" width="210" height="45" rx="4" fill="#0f172a" stroke="#334155"/>
                    <text x="345" y="123" fill="#e2e8f0" font-size="10" font-weight="600" text-anchor="middle">Express Backend (:3001)</text>
                    <text x="345" y="138" fill="#94a3b8" font-size="9" text-anchor="middle">Reads /vault/secrets/config.json</text>

                    <!-- Shared Volume -->
                    <rect x="240" y="157" width="210" height="30" rx="4" fill="#064e3b" stroke="#059669"/>
                    <text x="345" y="176" fill="#a7f3d0" font-size="10" font-weight="600" text-anchor="middle">📁 Injected config.json (emptyDir)</text>

                    <!-- Sidecar Container -->
                    <rect x="240" y="195" width="210" height="45" rx="4" fill="#0f172a" stroke="#7c3aed"/>
                    <text x="345" y="213" fill="#c084fc" font-size="10" font-weight="600" text-anchor="middle">Sidecar: vault-agent</text>
                    <text x="345" y="228" fill="#a855f7" font-size="9" text-anchor="middle">SA JWT login & secret render</text>

                    <!-- MongoDB Pod -->
                    <rect x="230" y="10" width="230" height="45" rx="6" fill="#1e293b" stroke="#10b981" stroke-width="1.5"/>
                    <text x="345" y="28" fill="#34d399" font-size="11" font-weight="700" text-anchor="middle">mongodb (Headless :27017)</text>
                    <text x="345" y="44" fill="#94a3b8" font-size="9" text-anchor="middle">DB Auth via Vault generated password</text>

                    <!-- Vault Box -->
                    <rect x="520" y="70" width="220" height="200" rx="8" fill="#0f172a" stroke="#0284c7" stroke-width="2"/>
                    <rect x="520" y="70" width="220" height="28" rx="8" fill="#0284c7"/>
                    <text x="630" y="89" fill="#ffffff" font-size="12" font-weight="700" text-anchor="middle">HashiCorp Vault Server</text>

                    <rect x="530" y="110" width="200" height="50" rx="4" fill="#1e293b" stroke="#3b82f6"/>
                    <text x="630" y="128" fill="#60a5fa" font-size="10" font-weight="700" text-anchor="middle">auth/kubernetes/mern-vault</text>
                    <text x="630" y="145" fill="#94a3b8" font-size="9" text-anchor="middle">Validates SA JWT with EKS OIDC</text>

                    <rect x="530" y="170" width="200" height="50" rx="4" fill="#1e293b" stroke="#10b981"/>
                    <text x="630" y="188" fill="#34d399" font-size="10" font-weight="700" text-anchor="middle">KV v2: apps/mern-vault</text>
                    <text x="630" y="205" fill="#94a3b8" font-size="9" text-anchor="middle">data/mongodb (user, password)</text>

                    <!-- Arrows -->
                    <!-- Browser to FE -->
                    <path d="M 80 80 L 80 135" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>
                    
                    <!-- FE to BE -->
                    <path d="M 170 185 L 225 185" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>

                    <!-- BE to MongoDB -->
                    <path d="M 345 105 L 345 60" stroke="#4ade80" stroke-width="2" fill="none" marker-end="url(#arr-g)"/>

                    <!-- Sidecar to Vault Auth (dashed purple) -->
                    <path d="M 450 215 C 480 215, 490 135, 515 135" stroke="#c084fc" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-p)"/>

                    <!-- Vault KV to Volume (dashed blue) -->
                    <path d="M 525 195 C 490 195, 480 172, 455 172" stroke="#38bdf8" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-b)"/>
                  </svg>
                </div>

                <div class="flow-step">
                  <span>1. <strong>Identity:</strong> Pod Projected ServiceAccount Token</span>
                  <span class="badge badge-purple">Kubernetes JWT</span>
                </div>
                <div class="flow-step">
                  <span>2. <strong>Auth Method:</strong> Vault Kubernetes Auth Backend</span>
                  <span class="badge badge-blue">auth/kubernetes/mern-vault</span>
                </div>
                <div class="flow-step">
                  <span>3. <strong>Secret Delivery:</strong> Vault Agent Injector Sidecar</span>
                  <span class="badge badge-green">/vault/secrets/config.json</span>
                </div>
                <div class="flow-step">
                  <span>4. <strong>Runtime Decoupling:</strong> No DB credentials in Env or Git</span>
                  <span class="badge badge-green">Zero-Secret App</span>
                </div>
              </div>

              <div class="card">
                <h2>Live Vault Injection Status</h2>
                <div id="vault-status"><pre>Loading status from backend...</pre></div>
              </div>

              <div class="card">
                <h2>Vault-Secured Database Messages</h2>
                <form id="addForm">
                  <input id="msg" placeholder="Write a message to MongoDB..." required />
                  <button type="submit">Send</button>
                </form>
                <ul id="list"></ul>
              </div>

              <script>
                const API = '/api';
                async function loadStatus() {
                  try {
                    const res = await fetch(API + '/vault-status');
                    const status = await res.json();
                    document.getElementById('vault-status').innerHTML = '<pre>' + JSON.stringify(status, null, 2) + '</pre>';
                  } catch(e) {
                    document.getElementById('vault-status').innerHTML = '<pre style="color:red">Backend API unreachable or secret missing</pre>';
                  }
                }
                async function loadItems() {
                  try {
                    const res = await fetch(API + '/items');
                    const items = await res.json();
                    document.getElementById('list').innerHTML = items.map(i => '<li><span>' + i.message + '</span><span class="meta">' + new Date(i.createdAt).toLocaleTimeString() + '</span></li>').join('');
                  } catch(e) { console.error(e); }
                }
                document.getElementById('addForm').onsubmit = async (e) => {
                  e.preventDefault();
                  const msg = document.getElementById('msg').value;
                  await fetch(API + '/items', { method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({message: msg}) });
                  document.getElementById('msg').value = '';
                  loadItems();
                };
                loadStatus();
                loadItems();
              </script>
            </body>
            </html>`;

            const server = http.createServer((req, res) => {
              if (req.url === '/health') {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ status: 'healthy' }));
                return;
              }

              // Proxy API calls directly to the internal mern-backend ClusterIP service
              if (req.url.startsWith('/api')) {
                const proxyReq = http.request({
                  hostname: 'mern-backend',
                  port: 3001,
                  path: req.url,
                  method: req.method,
                  headers: req.headers
                }, proxyRes => {
                  res.writeHead(proxyRes.statusCode, proxyRes.headers);
                  proxyRes.pipe(res, { end: true });
                });
                proxyReq.on('error', err => {
                  res.writeHead(502, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Backend gateway error: ' + err.message }));
                });
                req.pipe(proxyReq, { end: true });
                return;
              }

              res.writeHead(200, { 'Content-Type': 'text/html' });
              res.end(html);
            });

            server.listen(PORT, '0.0.0.0', () => console.log('MERN Frontend serving on port ' + PORT));
          JS
          ]

          port { container_port = 3000 }

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

  depends_on = [
    kubernetes_namespace_v1.app,
    module.eks.eks_managed_node_groups,
  ]
}

# ── Uptycs EDR sensor (IBM CISO requirement) ──────────────────────────────
module "uptycs" {
  count  = var.enable_uptycs ? 1 : 0
  source = "../../../_shared/uptycs-eks"

  uptycs_helm_repo_url = var.uptycs_helm_repo_url
  uptycs_chart_version = var.uptycs_chart_version
  uptycs_owner_email   = var.uptycs_owner_email
  uptycs_update_tag    = var.uptycs_update_tag

  depends_on = [module.eks.eks_managed_node_groups]
}
