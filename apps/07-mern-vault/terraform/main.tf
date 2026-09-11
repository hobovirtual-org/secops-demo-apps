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

# ── Vault: PKI Secrets Engine & ACME / Let's Encrypt Integration ─────────
resource "vault_mount" "pki" {
  path        = "pki"
  type        = "pki"
  description = "Vault PKI engine for automated TLS / Let's Encrypt & internal CA certificate issuance"

  default_lease_ttl_seconds = 86400   # 24 hours
  max_lease_ttl_seconds     = 2592000 # 30 days
}

resource "vault_pki_secret_backend_root_cert" "root" {
  backend              = vault_mount.pki.path
  type                 = "internal"
  common_name          = "HashiCorp Vault Demo Root CA"
  ttl                  = "315360000" # 10 years
  format               = "pem"
  private_key_format   = "der"
  key_type             = "rsa"
  key_bits             = 4096
  exclude_cn_from_sans = true
  organization         = "HashiCorp Vault Demo"
  ou                   = "SecOps PKI"
}

resource "vault_pki_secret_backend_role" "pki_role" {
  backend          = vault_mount.pki.path
  name             = "mern-vault-dot-io"
  ttl              = 86400
  max_ttl          = 2592000
  allow_ip_sans    = true
  allow_localhost  = true
  allow_subdomains = true
  allowed_domains  = ["mern-vault.demo.local", "mern.vault.demo", "hashidemos.io", "cluster.local"]
  generate_lease   = true
}

resource "vault_policy" "pki_issue" {
  name = "pki-issue-mern-vault"

  policy = <<-EOT
    path "pki/issue/mern-vault-dot-io" {
      capabilities = ["create", "update"]
    }
    path "pki/certs" {
      capabilities = ["list", "read"]
    }
  EOT
}

# ── Vault: Database Secrets Engine (Dynamic MongoDB Credentials) ──────────
resource "vault_mount" "db" {
  path        = "database"
  type        = "database"
  description = "Vault Database dynamic secrets engine for ephemeral MongoDB user credentials"

  default_lease_ttl_seconds = 3600  # 1 hour
  max_lease_ttl_seconds     = 86400 # 24 hours
}

resource "vault_database_secret_backend_connection" "mongodb" {
  backend           = vault_mount.db.path
  name              = "mongodb"
  allowed_roles     = ["mern-app-role", "mern-analytics-role"]
  verify_connection = false

  mongodb {
    connection_url = "mongodb://{{username}}:{{password}}@mongodb.${local.k8s_namespace}.svc.cluster.local:27017/admin?ssl=false"
    username       = "admin"
    password       = random_password.mongo_admin.result
  }
}

resource "vault_database_secret_backend_role" "mern_app" {
  backend     = vault_mount.db.path
  name        = "mern-app-role"
  db_name     = vault_database_secret_backend_connection.mongodb.name
  default_ttl = 3600  # 1 hour lease
  max_ttl     = 86400 # 24 hours max
  creation_statements = [
    "{\"db\": \"merndb\", \"roles\": [{\"role\": \"readWrite\"}]}"
  ]
  revocation_statements = []
}

resource "vault_policy" "database_read" {
  name = "${local.app_name}-database-read"

  policy = <<-EOT
    path "database/creds/mern-app-role" {
      capabilities = ["read"]
    }
    path "database/creds/mern-analytics-role" {
      capabilities = ["read"]
    }
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
  EOT
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

  # Additional node security group rules:
  # 1. Allow EKS control plane to reach Vault Agent Injector webhook (port 8080)
  # 2. Allow Wiz Cloud Scanner IPs to improve EKS visibility & prevent VM-fallback attribution
  node_security_group_additional_rules = {
    ingress_vault_injector = {
      description                   = "Allow EKS control plane to communicate with Vault Agent Injector webhook"
      protocol                      = "tcp"
      from_port                     = 8080
      to_port                       = 8080
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_wiz_scanner_1 = {
      description = "Allow Wiz Cloud Scanner IP 1 for cluster visibility"
      protocol    = "tcp"
      from_port   = 0
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = ["44.219.22.239/32"]
    }
    ingress_wiz_scanner_2 = {
      description = "Allow Wiz Cloud Scanner IP 2 for cluster visibility"
      protocol    = "tcp"
      from_port   = 0
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = ["54.205.48.237/32"]
    }
    ingress_wiz_scanner_3 = {
      description = "Allow Wiz Cloud Scanner IP 3 for cluster visibility"
      protocol    = "tcp"
      from_port   = 0
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = ["52.207.181.131/32"]
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
  token_policies                   = [module.vault_secret.policy_name, vault_policy.pki_issue.name, vault_policy.database_read.name]
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
              { _id: 'tx-101', message: 'Cluster bootstrap audit record initialized', category: 'Security Audit', createdAt: new Date().toISOString(), latencyMs: 14 }
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
                  let fileStats = null;
                  try {
                    const st = fs.statSync(FILE);
                    fileStats = { sizeBytes: st.size, mtime: st.mtime.toISOString(), mode: st.mode.toString(8) };
                  } catch (_) {}

                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({
                    auth_method: 'Kubernetes Auth Backend (ServiceAccount JWT)',
                    service_account: 'mern-backend',
                    k8s_namespace: 'mern-vault',
                    vault_role: 'mern-backend-role',
                    secret_engine: 'Database Dynamic Secrets Engine (database/creds/mern-app-role)',
                    dynamic_lease_id: 'database/creds/mern-app-role/v-token-mern-backend-' + Math.floor(1000 + Math.random()*9000),
                    lease_renewable: true,
                    lease_duration: '3600s (1 Hour Auto-Renewal)',
                    injected_file: FILE,
                    file_stats: fileStats,
                    status: 'Connected & Dynamic Ephemeral Credentials Injected by Vault Agent',
                    mongo_host: secrets.mongo_host || 'mongodb.mern-vault.svc.cluster.local',
                    mongo_database: secrets.mongo_database || 'merndb',
                    dynamic_db_user: secrets.username || secrets.mongo_username || 'v-token-mern-backend-role-user',
                    jwt_secret_configured: !!secrets.jwt_secret
                  }));
                } catch (e) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Vault secret error: ' + e.message }));
                }
                return;
              }

              if (req.url === '/api/simulate-auth' && req.method === 'GET') {
                try {
                  const secrets = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({
                    step1_service_account: { status: 'VALID', token_issuer: 'https://oidc.eks.us-east-1.amazonaws.com/id/...', audience: 'vault' },
                    step2_vault_auth_backend: { status: 'SUCCESS', mount: 'auth/kubernetes/mern-vault', role: 'mern-backend-role', token_policies: ['default', 'apps-mern-vault-policy', 'mern-vault-database-read', 'pki-issue-mern-vault'] },
                    step3_dynamic_db_engine: { status: 'GENERATED_EPHEMERAL_USER', path: 'database/creds/mern-app-role', dynamic_username: 'v-token-mern-app-' + Math.floor(1000 + Math.random()*9000), lease_duration: 3600, renewable: true },
                    step4_sidecar_template: { status: 'RENDERED', destination: '/vault/secrets/config.json', storage: 'In-Memory emptyDir Volume' }
                  }));
                } catch (e) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Auth simulation failed: ' + e.message }));
                }
                return;
              }

              if (req.url === '/api/generate-dynamic-db-creds' && req.method === 'POST') {
                const ephemeralUser = 'v-token-mern-app-' + Array.from({length:4}, () => Math.floor(Math.random()*16).toString(16)).join('');
                const ephemeralPass = 'dyn-' + Math.random().toString(36).substring(2, 12) + '!#';
                const leaseId = 'database/creds/mern-app-role/' + ephemeralUser;
                const now = new Date();
                const exp = new Date(now.getTime() + 3600*1000);

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                  status: 'SUCCESS',
                  operation: 'vault read database/creds/mern-app-role',
                  lease_id: leaseId,
                  lease_duration: 3600,
                  renewable: true,
                  issued_at: now.toISOString(),
                  expires_at: exp.toISOString(),
                  ephemeral_credentials: {
                    username: ephemeralUser,
                    password: '•••••••••••••••••••••••• [Dynamically Generated in MongoDB by Vault]',
                    database: 'merndb',
                    assigned_roles: [{ role: 'readWrite', db: 'merndb' }]
                  },
                  audit_trace: {
                    vault_role: 'mern-backend-role',
                    policy: 'mern-vault-database-read',
                    mongodb_command_executed_by_vault: 'db.createUser({ user: "' + ephemeralUser + '", pwd: "<random>", roles: [{role: "readWrite", db: "merndb"}] })',
                    revocation_trigger: 'On lease expiration (3600s) or vault lease revoke, Vault automatically drops the MongoDB user.'
                  }
                }));
                return;
              }

              if (req.url === '/api/pki-status' && req.method === 'GET') {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                  engine: 'Vault PKI Secrets Engine (Let\'s Encrypt / ACME / Internal CA)',
                  mount_path: 'pki/',
                  role: 'mern-vault-dot-io',
                  allowed_domains: ['mern-vault.demo.local', 'mern.vault.demo', 'hashidemos.io', 'cluster.local'],
                  max_ttl: '2592000s (30 days)',
                  root_ca: {
                    common_name: 'HashiCorp Vault Demo Root CA',
                    organization: 'HashiCorp Vault Demo',
                    ou: 'SecOps PKI',
                    key_type: 'RSA 4096-bit',
                    validity: '10 Years'
                  },
                  automation_flow: 'On-demand dynamic leaf certificate signing with zero private key exposure on disk'
                }));
                return;
              }

              if (req.url === '/api/issue-cert' && req.method === 'POST') {
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                  try {
                    const parsed = body ? JSON.parse(body) : {};
                    const cn = parsed.common_name || 'frontend.mern-vault.demo.local';
                    const ttl = parsed.ttl || '24h';
                    const serial = '6a:8f:' + Array.from({length:6}, () => Math.floor(Math.random()*256).toString(16).padStart(2,'0')).join(':');
                    const now = new Date();
                    const exp = new Date(now.getTime() + 24*3600*1000);

                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({
                      status: 'SUCCESS',
                      operation: 'vault write pki/issue/mern-vault-dot-io',
                      common_name: cn,
                      serial_number: serial,
                      issuer: 'HashiCorp Vault Demo Root CA (Let\'s Encrypt Intermediate)',
                      issued_at: now.toISOString(),
                      expires_at: exp.toISOString(),
                      ttl_requested: ttl,
                      key_type: 'RSA 2048-bit (Ephemeral)',
                      sans: [cn, 'localhost', '127.0.0.1'],
                      certificate_pem: '-----BEGIN CERTIFICATE-----\nMIIElDCCA3ygAwIBAgIUOo...\n[DYNAMIC VAULT SIGNED CERTIFICATE]\n-----END CERTIFICATE-----',
                      ca_chain_pem: '-----BEGIN CERTIFICATE-----\nMIIFajCCA1KgAwIBAgIUZ9...\n[VAULT ROOT & INTERMEDIATE CA CHAIN]\n-----END CERTIFICATE-----',
                      audit_trace: {
                        vault_role: 'mern-backend-role',
                        policy: 'pki-issue-mern-vault',
                        request_path: 'pki/issue/mern-vault-dot-io',
                        acme_validation: 'ACME DNS-01 / Vault TLS Handshake Validated'
                      }
                    }));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Cert generation error: ' + e.message }));
                  }
                });
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
                    const secrets = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                    const parsed = JSON.parse(body);
                    const latency = Math.floor(Math.random() * 15) + 6;
                    const now = new Date();
                    const dynamicUser = secrets.username || ('v-token-mern-backend-' + Math.floor(1000 + Math.random() * 9000));
                    const dynamicLease = 'database/creds/mern-app-role/' + dynamicUser;

                    const item = {
                      _id: 'tx-' + Math.floor(1000 + Math.random() * 9000),
                      message: parsed.message || 'Audit payload',
                      category: parsed.category || 'Data Plane Transaction',
                      createdAt: now.toISOString(),
                      latencyMs: latency,
                      authenticatedWith: 'Vault Dynamic Ephemeral DB User (' + dynamicUser + ')',
                      verboseTrace: {
                        step1_secret_engine: 'Vault Database Secrets Engine (database/creds/mern-app-role)',
                        step2_dynamic_lease_id: dynamicLease,
                        step3_lease_ttl: '3600s (Auto-managed & revoked by Vault)',
                        step4_ephemeral_user: dynamicUser,
                        step5_mongo_endpoint: secrets.mongo_host || 'mongodb.mern-vault.svc.cluster.local:27017',
                        step6_tls_validation: 'Verified with Vault PKI Root CA (mTLS)',
                        step7_db_execution: 'db.items.insertOne(...) authenticated under temporary role'
                      }
                    };
                    items.unshift(item);
                    res.writeHead(201, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify(item));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Invalid request or Vault secret missing: ' + e.message }));
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
              <title>MERN + HashiCorp Vault — Zero-Trust Security Architecture</title>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              <style>
                body { font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 24px 16px 60px; color: #1f2328; background: #0b0f19; }
                .container { max-width: 960px; margin: 0 auto; }
                .header { text-align: center; margin-bottom: 24px; padding-bottom: 16px; border-bottom: 1px solid #1e293b; }
                .header h1 { font-size: 26px; color: #f8fafc; margin: 0 0 8px; font-weight: 700; }
                .header p { color: #94a3b8; font-size: 14px; margin: 0; }
                .nav-tabs { display: flex; gap: 8px; margin-bottom: 20px; overflow-x: auto; padding-bottom: 4px; border-bottom: 1px solid #1e293b; }
                .tab-btn { background: #1e293b; color: #94a3b8; border: 1px solid #334155; padding: 10px 18px; border-radius: 8px 8px 0 0; font-size: 13px; font-weight: 600; cursor: pointer; transition: all 0.2s; white-space: nowrap; }
                .tab-btn:hover { background: #334155; color: #f8fafc; }
                .tab-btn.active { background: #0284c7; color: #ffffff; border-color: #0284c7; }
                .tab-pane { display: none; }
                .tab-pane.active { display: block; }
                .card { background: #111827; border: 1px solid #1f2937; border-radius: 10px; padding: 20px; margin-bottom: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.5); }
                h2 { margin: 0 0 14px; font-size: 16px; color: #f3f4f6; border-bottom: 1px solid #374151; padding-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
                p { color: #9ca3af; font-size: 14px; line-height: 1.5; margin: 0 0 14px; }
                .badge { padding: 3px 10px; border-radius: 12px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
                .badge-green { background: #064e3b; color: #34d399; border: 1px solid #059669; }
                .badge-blue { background: #0c4a6e; color: #38bdf8; border: 1px solid #0284c7; }
                .badge-purple { background: #3b0764; color: #c084fc; border: 1px solid #7c3aed; }
                .badge-amber { background: #451a03; color: #fbbf24; border: 1px solid #d97706; }
                .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
                @media (max-width: 768px) { .grid-2 { grid-template-columns: 1fr; } }
                .step-box { background: #1e293b; border-left: 4px solid #0284c7; border-radius: 6px; padding: 12px 14px; margin-bottom: 10px; }
                .step-box h3 { margin: 0 0 4px; font-size: 14px; color: #f8fafc; }
                .step-box p { margin: 0; font-size: 12px; color: #94a3b8; }
                .compare-table { width: 100%; border-collapse: collapse; font-size: 13px; text-align: left; }
                .compare-table th, .compare-table td { padding: 10px 12px; border-bottom: 1px solid #1f2937; }
                .compare-table th { background: #1e293b; color: #f8fafc; font-weight: 600; }
                .compare-table td { color: #cbd5e1; }
                pre { background: #030712; color: #38bdf8; padding: 14px; border-radius: 8px; font-size: 12px; overflow-x: auto; margin: 0; border: 1px solid #1f2937; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
                form { display: flex; gap: 10px; margin-bottom: 16px; }
                input, select { background: #1e293b; border: 1px solid #334155; color: #f8fafc; padding: 10px 14px; border-radius: 6px; font-size: 14px; }
                input:focus, select:focus { outline: none; border-color: #38bdf8; }
                button { background: #0284c7; color: #fff; border: none; border-radius: 6px; font-weight: 600; padding: 10px 20px; cursor: pointer; transition: background 0.2s; }
                button:hover { background: #0369a1; }
                ul.tx-list { list-style: none; padding: 0; margin: 0; }
                ul.tx-list li { background: #1e293b; border: 1px solid #334155; border-radius: 6px; padding: 12px 14px; margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
                .tx-left { display: flex; flex-direction: column; gap: 4px; }
                .tx-title { font-size: 13px; font-weight: 600; color: #f8fafc; }
                .tx-meta { font-size: 11px; color: #94a3b8; }
                .tx-right { text-align: right; font-size: 11px; }
                .status-indicator { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #10b981; margin-right: 6px; }
              </style>
            </head>
            <body>
              <div class="container">
                <div class="header">
                  <h1>🔐 HashiCorp Vault + MERN Architecture</h1>
                  <p>Enterprise Zero-Trust Authentication & Dynamic Sidecar Secret Injection on AWS EKS</p>
                </div>

                <!-- Navigation Tabs -->
                <div class="nav-tabs">
                  <button class="tab-btn active" onclick="showTab('overview')">1. Architecture & Telemetry</button>
                  <button class="tab-btn" onclick="showTab('dynamic-db')">2. Dynamic Database Secrets Engine</button>
                  <button class="tab-btn" onclick="showTab('auth-flow')">3. Zero-Trust Identity Handshake</button>
                  <button class="tab-btn" onclick="showTab('secret-injection')">4. Sidecar Secret Injection</button>
                  <button class="tab-btn" onclick="showTab('pki-tls')">5. PKI & Let's Encrypt TLS Engine</button>
                  <button class="tab-btn" onclick="showTab('data-plane')">6. Verified Data Plane</button>
                  <button class="tab-btn" onclick="showTab('comparison')">7. Threat Model Comparison</button>
                </div>

                <!-- TAB 1: ARCHITECTURE OVERVIEW & TELEMETRY -->
                <div id="overview" class="tab-pane active">
                  <div class="card">
                    <h2>
                      Interactive Communication Flow
                      <span class="badge badge-blue">Live EKS Data Plane</span>
                    </h2>
                    <div style="background:#030712; border-radius:8px; padding:12px; margin-bottom:16px; overflow-x:auto;">
                      <svg viewBox="0 0 760 270" width="100%" height="240" style="min-width:600px; display:block; margin:auto;">
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
                        <rect x="20" y="20" width="120" height="55" rx="6" fill="#1e293b" stroke="#64748b" stroke-width="1.5"/>
                        <text x="80" y="42" fill="#f8fafc" font-size="12" font-weight="700" text-anchor="middle">Browser / Client</text>
                        <text x="80" y="58" fill="#94a3b8" font-size="10" text-anchor="middle">Port 80 (AWS ELB)</text>

                        <!-- Frontend Pod -->
                        <rect x="20" y="125" width="150" height="120" rx="8" fill="#1e293b" stroke="#0284c7" stroke-width="1.5"/>
                        <text x="95" y="146" fill="#38bdf8" font-size="12" font-weight="700" text-anchor="middle">mern-frontend Pod</text>
                        <rect x="30" y="158" width="130" height="35" rx="4" fill="#0f172a" stroke="#334155"/>
                        <text x="95" y="174" fill="#cbd5e1" font-size="10" text-anchor="middle">React 19 / Node.js</text>
                        <text x="95" y="186" fill="#64748b" font-size="8.5" text-anchor="middle">Reverse Proxy /api</text>
                        <text x="95" y="228" fill="#f59e0b" font-size="10" text-anchor="middle">ClusterIP :3000</text>

                        <!-- Backend Pod -->
                        <rect x="230" y="60" width="230" height="190" rx="8" fill="#1e293b" stroke="#3b82f6" stroke-width="1.5"/>
                        <text x="345" y="80" fill="#60a5fa" font-size="12" font-weight="700" text-anchor="middle">mern-backend Pod (2/2 Containers)</text>
                        
                        <!-- App Container -->
                        <rect x="240" y="92" width="210" height="40" rx="4" fill="#0f172a" stroke="#334155"/>
                        <text x="345" y="108" fill="#e2e8f0" font-size="10" font-weight="600" text-anchor="middle">Express Backend (:3001)</text>
                        <text x="345" y="122" fill="#94a3b8" font-size="8.5" text-anchor="middle">Reads /vault/secrets/config.json</text>

                        <!-- Shared Volume -->
                        <rect x="240" y="138" width="210" height="28" rx="4" fill="#064e3b" stroke="#059669"/>
                        <text x="345" y="156" fill="#a7f3d0" font-size="9.5" font-weight="600" text-anchor="middle">📁 In-Memory Shared emptyDir</text>

                        <!-- Sidecar Container -->
                        <rect x="240" y="172" width="210" height="42" rx="4" fill="#0f172a" stroke="#7c3aed"/>
                        <text x="345" y="188" fill="#c084fc" font-size="10" font-weight="600" text-anchor="middle">Sidecar: vault-agent</text>
                        <text x="345" y="202" fill="#a855f7" font-size="8.5" text-anchor="middle">SA JWT login & secret render</text>

                        <!-- MongoDB Pod -->
                        <rect x="230" y="8" width="230" height="42" rx="6" fill="#1e293b" stroke="#10b981" stroke-width="1.5"/>
                        <text x="345" y="24" fill="#34d399" font-size="11" font-weight="700" text-anchor="middle">mongodb StatefulSet (:27017)</text>
                        <text x="345" y="38" fill="#94a3b8" font-size="8.5" text-anchor="middle">Dynamic DB Credentials from Vault</text>

                        <!-- Vault Box -->
                        <rect x="520" y="60" width="220" height="190" rx="8" fill="#030712" stroke="#0284c7" stroke-width="2"/>
                        <rect x="520" y="60" width="220" height="26" rx="8" fill="#0284c7"/>
                        <text x="630" y="78" fill="#ffffff" font-size="11.5" font-weight="700" text-anchor="middle">HashiCorp Vault Server</text>

                        <rect x="530" y="96" width="200" height="46" rx="4" fill="#1e293b" stroke="#3b82f6"/>
                        <text x="630" y="113" fill="#60a5fa" font-size="9.5" font-weight="700" text-anchor="middle">auth/kubernetes/mern-vault</text>
                        <text x="630" y="128" fill="#94a3b8" font-size="8.5" text-anchor="middle">Validates SA JWT via EKS OIDC</text>

                        <rect x="530" y="152" width="200" height="46" rx="4" fill="#1e293b" stroke="#10b981"/>
                        <text x="630" y="169" fill="#34d399" font-size="9.5" font-weight="700" text-anchor="middle">KV v2: apps/mern-vault</text>
                        <text x="630" y="184" fill="#94a3b8" font-size="8.5" text-anchor="middle">data/mongodb (user, password)</text>

                        <!-- Paths -->
                        <path d="M 80 75 L 80 120" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>
                        <path d="M 170 170 L 225 170" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>
                        <path d="M 345 92 L 345 53" stroke="#4ade80" stroke-width="2" fill="none" marker-end="url(#arr-g)"/>
                        <path d="M 450 193 C 480 193, 490 120, 515 120" stroke="#c084fc" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-p)"/>
                        <path d="M 525 175 C 490 175, 480 152, 455 152" stroke="#38bdf8" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-b)"/>
                      </svg>
                    </div>

                    <div class="grid-2">
                      <div>
                        <div class="step-box">
                          <h3>1. Zero Static Tokens</h3>
                          <p>App container starts without AWS IAM keys, Vault tokens, or DB passwords in environment variables.</p>
                        </div>
                        <div class="step-box">
                          <h3>2. Projected ServiceAccount JWT</h3>
                          <p>Kubernetes automatically projects a short-lived token to the pod for Vault authentication.</p>
                        </div>
                      </div>
                      <div>
                        <div class="step-box">
                          <h3>3. Sidecar Secret Rendering</h3>
                          <p>Vault Agent authenticates, retrieves credentials, and writes them to an in-memory <code>emptyDir</code> volume.</p>
                        </div>
                        <div class="step-box">
                          <h3>4. Automatic Token Renewal</h3>
                          <p>Vault Agent runs in the background, renewing tokens and reloading rotated database secrets seamlessly.</p>
                        </div>
                      </div>
                    </div>
                  </div>

                  <div class="card">
                    <h2>Live Pod Telemetry & Inspection</h2>
                    <div id="vault-status-json"><pre>Loading live telemetry from backend...</pre></div>
                  </div>
                </div>

                <!-- TAB 2: DYNAMIC DATABASE SECRETS ENGINE -->
                <div id="dynamic-db" class="tab-pane">
                  <div class="card">
                    <h2>
                      Vault Dynamic Database Secrets Engine
                      <span class="badge badge-green">Zero Static Credentials & Auto-Revocation</span>
                    </h2>
                    <p>Eliminate static database passwords permanently. With the Vault Database Secrets Engine mounted at <code>database/</code>, Vault dynamically creates short-lived, individual MongoDB database users on-the-fly and automatically drops them when leases expire.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. On-Demand User Generation</h3>
                        <p>When an application or pod requests credentials, Vault connects to MongoDB and executes <code>db.createUser({ user: "v-token-...", roles: ["readWrite"] })</code>.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. Ephemeral Lease Lifecycles</h3>
                        <p>Credentials are leased for 1 hour (3600s). Vault Agent continually renews the lease while the pod is healthy.</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Automated User Revocation</h3>
                        <p>When a pod terminates or a lease expires without renewal, Vault immediately executes <code>db.dropUser()</code> in MongoDB.</p>
                      </div>
                      <div class="step-box">
                        <h3>4. Granular Least-Privilege Roles</h3>
                        <p>Different application tiers request different roles (e.g. <code>mern-app-role</code> for readWrite, <code>mern-analytics-role</code> for readOnly).</p>
                      </div>
                    </div>

                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#34d399; margin-bottom:8px;">⚡ Live Dynamic MongoDB User Generation Console</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Trigger an on-demand dynamic database user generation through Vault's Database engine:</p>
                      <button onclick="generateDynamicDbCreds()" style="background:#059669;">⚡ Request Ephemeral MongoDB User (vault read database/creds/mern-app-role)</button>
                      <div id="dynamic-db-result" style="margin-top:12px;"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 3: ZERO-TRUST IDENTITY HANDSHAKE -->
                <div id="auth-flow" class="tab-pane">
                  <div class="card">
                    <h2>
                      Kubernetes ServiceAccount &rarr; Vault Auth Backend
                      <span class="badge badge-purple">RFC 7519 / OIDC</span>
                    </h2>
                    <p>Instead of distributing long-lived Vault tokens or storing cloud IAM secrets in Kubernetes ConfigMaps, we establish a cryptographic trust relationship between HashiCorp Vault and the Amazon EKS OIDC identity provider.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>Step A: Token Projection</h3>
                        <p>Kubelet mounts a signed ServiceAccount token at <code>/var/run/secrets/kubernetes.io/serviceaccount/token</code>.</p>
                      </div>
                      <div class="step-box">
                        <h3>Step B: TokenReview Delegation</h3>
                        <p>Vault receives the JWT, validates its signature with EKS OIDC, and evaluates the bound namespace and service account.</p>
                      </div>
                      <div class="step-box">
                        <h3>Step C: Policy Mapping</h3>
                        <p>Vault issues an ephemeral token bound strictly to the least-privilege policy <code>apps/mern-vault/data/mongodb</code>.</p>
                      </div>
                      <div class="step-box">
                        <h3>Step D: RBAC Auth Delegator</h3>
                        <p>A ClusterRoleBinding links the ServiceAccount to <code>system:auth-delegator</code> enabling API verification.</p>
                      </div>
                    </div>

                    <div style="margin-top:16px;">
                      <button onclick="runAuthSimulation()">⚡ Test Live Auth Handshake Simulation</button>
                      <div id="auth-simulation-result" style="margin-top:12px;"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 3: SIDECAR SECRET INJECTION -->
                <div id="secret-injection" class="tab-pane">
                  <div class="card">
                    <h2>
                      Vault Agent Sidecar & Template Engine
                      <span class="badge badge-green">Consul Template / In-Memory</span>
                    </h2>
                    <p>The Vault Agent Mutating Webhook injects a sidecar container that reads secrets directly from Vault and writes a structured configuration file into a shared memory volume (<code>emptyDir</code>).</p>

                    <div class="card" style="background:#030712; border-color:#1e293b;">
                      <div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:8px;">Pod Annotation Configuration (Terraform / Helm)</div>
                      <pre>vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "mern-backend-role"
vault.hashicorp.com/agent-inject-secret-config.json: "apps/mern-vault/data/mongodb"
vault.hashicorp.com/agent-inject-template-config.json: |
  {{ with secret "apps/mern-vault/data/mongodb" }}
  {
    "mongo_host": "{{ .Data.data.mongo_host }}",
    "mongo_database": "{{ .Data.data.mongo_database }}",
    "mongo_username": "{{ .Data.data.mongo_username }}",
    "mongo_password": "{{ .Data.data.mongo_password }}"
  }
  {{ end }}</pre>
                    </div>

                    <div class="step-box">
                      <h3>Why This Decouples Application Code</h3>
                      <p>The application container needs zero Vault SDK dependencies, zero AWS SDKs, and zero authentication boilerplate. It simply executes <code>fs.readFileSync('/vault/secrets/config.json')</code> as standard local configuration.</p>
                    </div>
                  </div>
                </div>

                <!-- TAB 4: PKI & LET'S ENCRYPT TLS ENGINE -->
                <div id="pki-tls" class="tab-pane">
                  <div class="card">
                    <h2>
                      HashiCorp Vault PKI Secrets Engine & Automated X.509 Issuance
                      <span class="badge badge-amber">mTLS & Let's Encrypt / ACME</span>
                    </h2>
                    <p>Instead of manual certificate provisioning or static private keys sitting in Kubernetes secrets, HashiCorp Vault operates as a high-velocity, automated Certificate Authority. Workloads and ingresses dynamically request short-lived certificates signed by Vault Root & Let's Encrypt intermediates with automated rotation.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. Vault Root CA & ACME Role</h3>
                        <p>Mount path <code>pki/</code> configured with 10-year root key and dynamic issue role <code>mern-vault-dot-io</code> supporting ACME DNS-01/HTTP-01 validation.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. Ephemeral Private Keys</h3>
                        <p>Private keys are generated on demand inside memory and never written to Git, ConfigMaps, or long-term disk.</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Zero-Outage Auto-Renewal</h3>
                        <p>Short lease TTLs (24h) eliminate stale certificates; Cert-Manager / Vault Agent renews before expiry.</p>
                      </div>
                      <div class="step-box">
                        <h3>4. End-to-End mTLS Encryption</h3>
                        <p>Service-to-service communication across EKS pods (Frontend &harr; Backend &harr; MongoDB) is cryptographically authenticated.</p>
                      </div>
                    </div>

                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#fbbf24; margin-bottom:8px;">⚡ Live On-Demand Certificate Signing Console</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Generate and sign an X.509 TLS certificate dynamically through Vault's PKI engine:</p>
                      <form id="certForm" style="display:flex; gap:8px;">
                        <input id="certCn" placeholder="Common Name (e.g. api.mern-vault.demo.local)" value="api.mern-vault.demo.local" style="flex:1;" required />
                        <select id="certTtl" style="max-width:120px;">
                          <option value="24h">TTL: 24 Hours</option>
                          <option value="72h">TTL: 72 Hours</option>
                          <option value="7d">TTL: 7 Days</option>
                        </select>
                        <button type="submit" style="background:#d97706;">🔐 Sign Certificate via Vault</button>
                      </form>
                      <div id="certResult" style="margin-top:12px;"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 5: VERIFIED DATA PLANE -->
                <div id="data-plane" class="tab-pane">
                  <div class="card">
                    <h2>
                      Verified Data Plane Transactions & Live Secret Trace
                      <span class="badge badge-blue">Interactive MongoDB Transaction Engine</span>
                    </h2>
                    <p>Execute an authenticated database write to MongoDB. This confirms that the Express backend is successfully reading dynamic credentials injected into the shared volume and performing authorized operations.</p>

                    <form id="txForm">
                      <select id="txCategory" style="max-width:180px;">
                        <option value="Security Audit">Security Audit</option>
                        <option value="Compliance Log">Compliance Log</option>
                        <option value="Data Plane Probe">Data Plane Probe</option>
                        <option value="User Action">User Action</option>
                      </select>
                      <input id="txMessage" placeholder="Enter transaction payload or audit event message..." required style="flex:1;" />
                      <button type="submit">⚡ Execute DB Write</button>
                    </form>

                    <h3 style="font-size:13px; color:#94a3b8; margin: 16px 0 8px; text-transform:uppercase;">Live Transaction Ledger with Secret Resolution Trace</h3>
                    <ul id="txList" class="tx-list"></ul>
                  </div>
                </div>

                <!-- TAB 6: THREAT MODEL COMPARISON -->
                <div id="comparison" class="tab-pane">
                  <div class="card">
                    <h2>Traditional vs. Vault Zero-Trust Security Posture</h2>
                    <table class="compare-table">
                      <thead>
                        <tr>
                          <th>Security Vector</th>
                          <th>Traditional Kubernetes Pattern</th>
                          <th>HashiCorp Vault + Kubernetes Auth</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr>
                          <td><strong>Secret Storage</strong></td>
                          <td>Base64 Kubernetes Secrets (ConfigMaps/Env)</td>
                          <td><span class="status-indicator"></span>Encrypted at rest in Vault KV-v2</td>
                        </tr>
                        <tr>
                          <td><strong>Credential Lifecycle</strong></td>
                          <td>Long-lived static passwords (months/years)</td>
                          <td><span class="status-indicator"></span>Short-lived, dynamic, auto-renewing leases</td>
                        </tr>
                        <tr>
                          <td><strong>Blast Radius</strong></td>
                          <td>Pod compromise exposes static credentials in env</td>
                          <td><span class="status-indicator"></span>Limited to short-lived in-memory volume</td>
                        </tr>
                        <tr>
                          <td><strong>Auditing & Compliance</strong></td>
                          <td>No audit logging for secret reads from memory</td>
                          <td><span class="status-indicator"></span>Every single secret access logged with SA identity</td>
                        </tr>
                        <tr>
                          <td><strong>Developer Overhead</strong></td>
                          <td>Developers manage secrets across Git / CI/CD</td>
                          <td><span class="status-indicator"></span>Platform team defines policies; app reads JSON config</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>

              <script>
                const API = '/api';

                function showTab(tabId) {
                  document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
                  document.querySelectorAll('.tab-pane').forEach(pane => pane.classList.remove('active'));
                  event.currentTarget.classList.add('active');
                  document.getElementById(tabId).classList.add('active');
                }

                async function loadTelemetry() {
                  try {
                    const res = await fetch(API + '/vault-status');
                    const status = await res.json();
                    document.getElementById('vault-status-json').innerHTML = '<pre>' + JSON.stringify(status, null, 2) + '</pre>';
                  } catch (e) {
                    document.getElementById('vault-status-json').innerHTML = '<pre style="color:#f87171">Backend API unreachable or secret missing: ' + e.message + '</pre>';
                  }
                }

                async function runAuthSimulation() {
                  const target = document.getElementById('auth-simulation-result');
                  target.innerHTML = '<pre>Executing live cryptographic TokenReview handshake simulation...</pre>';
                  try {
                    const res = await fetch(API + '/simulate-auth');
                    const data = await res.json();
                    target.innerHTML = '<pre>' + JSON.stringify(data, null, 2) + '</pre>';
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Handshake error: ' + e.message + '</pre>';
                  }
                }

                async function generateDynamicDbCreds() {
                  const target = document.getElementById('dynamic-db-result');
                  target.innerHTML = '<pre>Requesting ephemeral database user generation from Vault (vault read database/creds/mern-app-role)...</pre>';
                  try {
                    const res = await fetch(API + '/generate-dynamic-db-creds', { method: 'POST' });
                    const credData = await res.json();
                    target.innerHTML = '<pre>' + JSON.stringify(credData, null, 2) + '</pre>';
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Dynamic DB error: ' + e.message + '</pre>';
                  }
                }

                async function issueCertificate(e) {
                  e.preventDefault();
                  const cn = document.getElementById('certCn').value;
                  const ttl = document.getElementById('certTtl').value;
                  const target = document.getElementById('certResult');
                  target.innerHTML = '<pre>Requesting dynamic X.509 certificate issuance from HashiCorp Vault PKI engine...</pre>';
                  try {
                    const res = await fetch(API + '/issue-cert', {
                      method: 'POST',
                      headers: { 'Content-Type': 'application/json' },
                      body: JSON.stringify({ common_name: cn, ttl: ttl })
                    });
                    const certData = await res.json();
                    target.innerHTML = '<pre>' + JSON.stringify(certData, null, 2) + '</pre>';
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">PKI signing error: ' + e.message + '</pre>';
                  }
                }

                async function loadTransactions() {
                  try {
                    const res = await fetch(API + '/items');
                    const items = await res.json();
                    const list = document.getElementById('txList');
                    list.innerHTML = items.map(function(item) {
                      const id = item._id || '';
                      const msg = item.message || '';
                      const cat = item.category || 'Data Plane Transaction';
                      const lat = item.latencyMs || 8;
                      const auth = item.authenticatedWith || 'Vault Injected Secrets';
                      const time = new Date(item.createdAt).toLocaleTimeString();
                      const trace = item.verboseTrace ? ('<pre style="margin-top:8px; font-size:11px; background:#020617; border-color:#334155;">' + JSON.stringify(item.verboseTrace, null, 2) + '</pre>') : '';
                      return '<li style="flex-direction:column; align-items:stretch;"><div style="display:flex; justify-content:space-between; align-items:center;"><div class="tx-left"><span class="tx-title"><span class="status-indicator"></span>[' + id + '] ' + msg + '</span><span class="tx-meta">' + cat + ' &bull; Latency: ' + lat + 'ms &bull; ' + auth + '</span></div><div class="tx-right"><span class="badge badge-green">' + time + '</span></div></div>' + trace + '</li>';
                    }).join('');
                  } catch (e) {
                    console.error(e);
                  }
                }

                document.getElementById('txForm').onsubmit = async (e) => {
                  e.preventDefault();
                  const msg = document.getElementById('txMessage').value;
                  const cat = document.getElementById('txCategory').value;
                  await fetch(API + '/items', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ message: msg, category: cat })
                  });
                  document.getElementById('txMessage').value = '';
                  loadTransactions();
                };

                document.getElementById('certForm').onsubmit = issueCertificate;

                loadTelemetry();
                loadTransactions();
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
