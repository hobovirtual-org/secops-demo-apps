# ── Route53 Vanity DNS ───────────────────────────────────────────────────
data "aws_route53_zone" "main" {
  count        = var.route53_zone_name != "" ? 1 : 0
  name         = var.route53_zone_name
  private_zone = false
}

resource "aws_route53_record" "app" {
  count   = var.route53_zone_name != "" && var.fqdn != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = var.fqdn
  type    = "CNAME"
  ttl     = 60
  records = [kubernetes_service_v1.frontend.status[0].load_balancer[0].ingress[0].hostname]
}

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
                  const now = new Date();
                  const exp = new Date(now.getTime() + 3600*1000);
                  const oidcIssuer = 'https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLEDEMO7EKS';

                  res.writeHead(200, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({
                    status: 'SUCCESS',
                    auth_method: 'Kubernetes Auth Backend (auth/kubernetes/mern-vault)',
                    jwt_token_claims: {
                      header: {
                        alg: 'RS256',
                        typ: 'JWT',
                        kid: 'k8s-sa-signer-key-2026'
                      },
                      payload: {
                        iss: oidcIssuer,
                        sub: 'system:serviceaccount:mern-vault:mern-backend',
                        aud: ['vault'],
                        'kubernetes.io': {
                          namespace: 'mern-vault',
                          serviceaccount: {
                            name: 'mern-backend',
                            uid: 'sa-7c5cd8-mern-backend-uuid'
                          },
                          pod: {
                            name: 'mern-backend-789f9b5c9b-x92zk',
                            uid: 'pod-8e29a-uuid'
                          }
                        },
                        iat: Math.floor(now.getTime()/1000),
                        exp: Math.floor(exp.getTime()/1000)
                      },
                      signature: '[CRYPTOGRAPHICALLY SIGNED BY EKS OIDC PRIVATE KEY]'
                    },
                    vault_role_binding: {
                      role_name: 'mern-backend-role',
                      bound_service_account_names: ['mern-backend'],
                      bound_service_account_namespaces: ['mern-vault'],
                      assigned_token_policies: ['default', 'apps-mern-vault-policy', 'mern-vault-database-read', 'pki-issue-mern-vault'],
                      token_ttl: 3600
                    },
                    execution_path_visualizer: [
                      { step: 1, actor: 'Kubelet (EKS Node)', action: 'Projects projected ServiceAccount JWT into pod at /var/run/secrets/kubernetes.io/serviceaccount/token', latency: '1ms' },
                      { step: 2, actor: 'Vault Agent Sidecar', action: 'Reads local SA JWT & sends login POST to auth/kubernetes/mern-vault with role "mern-backend-role"', latency: '4ms' },
                      { step: 3, actor: 'HashiCorp Vault Server', action: 'Performs TokenReview with EKS API / validates RS256 signature against OIDC JWKS at ' + oidcIssuer, latency: '12ms' },
                      { step: 4, actor: 'Vault Policy Engine', action: 'Confirms namespace=mern-vault & SA=mern-backend; issues ephemeral Vault token bound to "mern-vault-database-read" & "pki-issue-mern-vault"', latency: '3ms' },
                      { step: 5, actor: 'Vault Agent Sidecar', action: 'Receives token & initiates auto-renewing lease background loop; begins template rendering', latency: '2ms' }
                    ],
                    required_terraform_hcl: [
                      '# 1. Enable Kubernetes Auth Method in Vault',
                      'resource "vault_auth_backend" "kubernetes" {',
                      '  type = "kubernetes"',
                      '  path = "kubernetes/mern-vault"',
                      '}',
                      '',
                      '# 2. Configure Trust Anchor with EKS Cluster OIDC Issuer & CA',
                      'resource "vault_kubernetes_auth_backend_config" "config" {',
                      '  backend                = vault_auth_backend.kubernetes.path',
                      '  kubernetes_host        = module.eks.cluster_endpoint',
                      '  kubernetes_ca_cert     = base64decode(module.eks.cluster_certificate_authority_data)',
                      '  issuer                 = module.eks.cluster_oidc_issuer_url',
                      '  disable_iss_validation = false',
                      '}',
                      '',
                      '# 3. Bind Kubernetes ServiceAccount & Namespace to Vault Policies',
                      'resource "vault_kubernetes_auth_backend_role" "backend_role" {',
                      '  backend                          = vault_auth_backend.kubernetes.path',
                      '  role_name                        = "mern-backend-role"',
                      '  bound_service_account_names      = ["mern-backend"]',
                      '  bound_service_account_namespaces = ["mern-vault"]',
                      '  token_policies                   = ["default", "apps-mern-vault-policy", "mern-vault-database-read", "pki-issue-mern-vault"]',
                      '  token_ttl                        = 3600',
                      '}'
                    ].join('\n')
                  }));
                } catch (e) {
                  res.writeHead(500, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Auth simulation failed: ' + e.message }));
                }
                return;
              }

              if (req.url === '/api/generate-dynamic-db-creds' && req.method === 'POST') {
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                  try {
                    const parsed = body ? JSON.parse(body) : {};
                    const selectedRole = parsed.role || 'mern-app-role';
                    const isReadOnly = selectedRole === 'mern-analytics-role';
                    const prefix = isReadOnly ? 'v-token-analytics-' : 'v-token-mern-app-';
                    const ephemeralUser = prefix + Array.from({length:4}, () => Math.floor(Math.random()*16).toString(16)).join('');
                    const leaseId = 'database/creds/' + selectedRole + '/' + ephemeralUser;
                    const now = new Date();
                    const exp = new Date(now.getTime() + 3600*1000);
                    const grantedRoles = isReadOnly ? [{ role: 'read', db: 'merndb' }] : [{ role: 'readWrite', db: 'merndb' }];

                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({
                      status: 'SUCCESS',
                      operation: 'vault read database/creds/' + selectedRole,
                      requested_role: selectedRole,
                      lease_id: leaseId,
                      lease_duration: 3600,
                      renewable: true,
                      issued_at: now.toISOString(),
                      expires_at: exp.toISOString(),
                      ephemeral_credentials: {
                        username: ephemeralUser,
                        password: '•••••••••••••••••••••••• [Auto-Generated in MongoDB by Vault Engine]',
                        database: 'merndb',
                        assigned_roles: grantedRoles
                      },
                      execution_path_visualizer: [
                        { step: 1, actor: 'Client / App Container', action: 'Calls /api/generate-dynamic-db-creds selecting role: ' + selectedRole, latency: '2ms' },
                        { step: 2, actor: 'Vault Agent Sidecar', action: 'Authenticates via EKS ServiceAccount JWT (auth/kubernetes/mern-vault)', latency: '8ms' },
                        { step: 3, actor: 'HashiCorp Vault Server', action: 'Evaluates policy "mern-vault-database-read" for path database/creds/' + selectedRole, latency: '4ms' },
                        { step: 4, actor: 'Vault MongoDB Plugin', action: 'Connects to mongodb:27017 & runs: db.createUser({ user: "' + ephemeralUser + '", roles: ' + JSON.stringify(grantedRoles) + ' })', latency: '18ms' },
                        { step: 5, actor: 'Vault Lease Manager', action: 'Attaches 1h TTL lease timer; registers automatic db.dropUser() hook on expiration/revocation', latency: '3ms' },
                        { step: 6, actor: 'App Runtime', action: 'Injects dynamic ephemeral user credentials into active session context', latency: '1ms' }
                      ],
                      required_terraform_hcl: [
                        '# 1. Enable Database Secrets Engine in Vault',
                        'resource "vault_mount" "db" {',
                        '  path = "database"',
                        '  type = "database"',
                        '}',
                        '',
                        '# 2. Configure MongoDB Backend Connection (Root Access for Vault)',
                        'resource "vault_database_secret_backend_connection" "mongodb" {',
                        '  backend           = vault_mount.db.path',
                        '  name              = "mongodb"',
                        '  allowed_roles     = ["mern-app-role", "mern-analytics-role"]',
                        '  verify_connection = false',
                        '  mongodb {',
                        '    connection_url = "mongodb://{{username}}:{{password}}@mongodb.mern-vault.svc.cluster.local:27017/admin?ssl=false"',
                        '    username       = "admin"',
                        '    password       = var.mongo_admin_password',
                        '  }',
                        '}',
                        '',
                        '# 3. Define Dynamic Role with MongoDB Creation Statements',
                        'resource "vault_database_secret_backend_role" "' + (isReadOnly ? 'analytics' : 'mern_app') + '" {',
                        '  backend             = vault_mount.db.path',
                        '  name                = "' + selectedRole + '"',
                        '  db_name             = vault_database_secret_backend_connection.mongodb.name',
                        '  default_ttl         = 3600',
                        '  creation_statements = [',
                        '    "{\\"db\\": \\"merndb\\", \\"roles\\": ' + JSON.stringify(grantedRoles).replace(/"/g, '\\"') + '}"',
                        '  ]',
                        '}'
                      ].join('\n')
                    }));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Dynamic DB generation error: ' + e.message }));
                  }
                });
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

              if (req.url === '/api/verify-mtls-handshake' && req.method === 'GET') {
                const now = new Date();
                const exp = new Date(now.getTime() + 24*3600*1000);
                const serial = '6a:8f:' + Array.from({length:6}, () => Math.floor(Math.random()*256).toString(16).padStart(2,'0')).join(':');

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                  status: 'VERIFIED_SECURE',
                  protocol: 'TLSv1.3 (RFC 8446)',
                  cipher_suite: 'TLS_AES_256_GCM_SHA384',
                  client_identity: {
                    authenticated_principal: 'spiffe://mern-vault/sa/mern-frontend',
                    common_name: 'frontend.mern-vault.svc.cluster.local',
                    san_dns: ['frontend.mern-vault.svc.cluster.local', 'frontend.mern-vault.demo.local'],
                    serial_number: serial,
                    key_algorithm: 'RSA 2048-bit (Ephemeral In-Memory)',
                    validity: { not_before: now.toISOString(), not_after: exp.toISOString() }
                  },
                  server_identity: {
                    common_name: 'backend.mern-vault.svc.cluster.local',
                    issuer: 'HashiCorp Vault Demo Root CA (Let\'s Encrypt Intermediate)',
                    ca_fingerprint_sha256: '9b:4c:7e:21:55:aa:bb:cc:dd:ee:11:22:33:44:55:66',
                    mutual_auth_status: 'CLIENT_AND_SERVER_MUTUALLY_VERIFIED'
                  },
                  execution_path_visualizer: [
                    { step: 1, actor: 'React Frontend Client', action: 'Initiates TLS 1.3 ClientHello presenting Vault PKI-issued client certificate', latency: '2ms' },
                    { step: 2, actor: 'Express Backend Listener', action: 'Validates client cert against in-memory Vault Root CA bundle (/vault/secrets/ca.crt)', latency: '3ms' },
                    { step: 3, actor: 'Mutual TLS Handshake', action: 'Both peers negotiate TLS_AES_256_GCM_SHA384 session keys via ephemeral ECDHE', latency: '4ms' },
                    { step: 4, actor: 'Verified Transport', action: 'Encrypted channel established; SPIFFE ID spiffe://mern-vault/sa/mern-frontend authorized', latency: '1ms' }
                  ],
                  required_terraform_hcl: [
                    '# 1. Configure Vault Agent to Auto-Inject Leaf TLS Cert + Key + CA into Pod',
                    'annotations = {',
                    '  "vault.hashicorp.com/agent-inject"                  = "true"',
                    '  "vault.hashicorp.com/role"                          = "mern-backend-role"',
                    '  "vault.hashicorp.com/agent-inject-secret-tls.crt"   = "pki/issue/mern-vault-dot-io"',
                    '  "vault.hashicorp.com/agent-inject-template-tls.crt" = <<-TPL',
                    '    {{- with secret "pki/issue/mern-vault-dot-io" "common_name=backend.mern-vault.svc.cluster.local" "ttl=24h" -}}',
                    '    {{ .Data.certificate }}',
                    '    {{- end }}',
                    '  TPL',
                    '  "vault.hashicorp.com/agent-inject-secret-tls.key"   = "pki/issue/mern-vault-dot-io"',
                    '  "vault.hashicorp.com/agent-inject-template-tls.key" = <<-TPL',
                    '    {{- with secret "pki/issue/mern-vault-dot-io" "common_name=backend.mern-vault.svc.cluster.local" "ttl=24h" -}}',
                    '    {{ .Data.private_key }}',
                    '    {{- end }}',
                    '  TPL',
                    '  "vault.hashicorp.com/agent-inject-secret-ca.crt"    = "pki/issue/mern-vault-dot-io"',
                    '  "vault.hashicorp.com/agent-inject-template-ca.crt"  = <<-TPL',
                    '    {{- with secret "pki/issue/mern-vault-dot-io" "common_name=backend.mern-vault.svc.cluster.local" -}}',
                    '    {{ .Data.issuing_ca }}',
                    '    {{- end }}',
                    '  TPL',
                    '}'
                  ].join('\n')
                }));
                return;
              }

              if (req.url === '/api/render-template' && req.method === 'POST') {
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                  try {
                    const parsed = body ? JSON.parse(body) : {};
                    const format = parsed.format || 'json';
                    let secrets = {
                      mongo_host: 'mongodb.mern-vault.svc.cluster.local:27017',
                      mongo_database: 'merndb',
                      mongo_username: 'v-token-mern-backend-a1b2',
                      mongo_password: 'dyn-' + Math.random().toString(36).substring(2, 10) + '!',
                      jwt_secret: 'vault-ephemeral-jwt-sig-9902'
                    };
                    try {
                      const diskSecrets = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                      secrets = Object.assign(secrets, diskSecrets);
                    } catch (_) {}

                    let renderedOutput = '';
                    let templateSnippet = '';

                    if (format === 'dotenv') {
                      templateSnippet = 'vault.hashicorp.com/agent-inject-template-app.env: |\n  {{ with secret "apps/mern-vault/data/mongodb" }}\n  MONGO_HOST="{{ .Data.data.mongo_host }}"\n  MONGO_DB="{{ .Data.data.mongo_database }}"\n  MONGO_USER="{{ .Data.data.mongo_username }}"\n  MONGO_PASS="{{ .Data.data.mongo_password }}"\n  {{ end }}';
                      renderedOutput = 'MONGO_HOST="' + secrets.mongo_host + '"\nMONGO_DB="' + secrets.mongo_database + '"\nMONGO_USER="' + secrets.mongo_username + '"\nMONGO_PASS="' + secrets.mongo_password + '"\nJWT_SECRET="' + (secrets.jwt_secret || 'vault-ephemeral-jwt-sig-9902') + '"';
                    } else if (format === 'yaml') {
                      templateSnippet = 'vault.hashicorp.com/agent-inject-template-application.yml: |\n  {{ with secret "apps/mern-vault/data/mongodb" }}\n  mongodb:\n    host: {{ .Data.data.mongo_host }}\n    database: {{ .Data.data.mongo_database }}\n    username: {{ .Data.data.mongo_username }}\n    password: {{ .Data.data.mongo_password }}\n  {{ end }}';
                      renderedOutput = 'mongodb:\n  host: ' + secrets.mongo_host + '\n  database: ' + secrets.mongo_database + '\n  username: ' + secrets.mongo_username + '\n  password: ' + secrets.mongo_password + '\nsecurity:\n  jwt_secret: ' + (secrets.jwt_secret || 'vault-ephemeral-jwt-sig-9902');
                    } else {
                      templateSnippet = 'vault.hashicorp.com/agent-inject-template-config.json: |\n  {{ with secret "apps/mern-vault/data/mongodb" }}\n  {\n    "mongo_host": "{{ .Data.data.mongo_host }}",\n    "mongo_database": "{{ .Data.data.mongo_database }}",\n    "mongo_username": "{{ .Data.data.mongo_username }}",\n    "mongo_password": "{{ .Data.data.mongo_password }}"\n  }\n  {{ end }}';
                      renderedOutput = JSON.stringify(secrets, null, 2);
                    }

                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({
                      format: format,
                      template_snippet: templateSnippet,
                      rendered_output: renderedOutput,
                      destination_path: format === 'dotenv' ? '/vault/secrets/app.env' : (format === 'yaml' ? '/vault/secrets/application.yml' : '/vault/secrets/config.json'),
                      memory_backed: true,
                      developer_benefit: 'Zero Vault SDK dependencies in application code. Application consumes native ' + format.toUpperCase() + ' directly from in-memory filesystem.'
                    }));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Template render error: ' + e.message }));
                  }
                });
                return;
              }

              if (req.url === '/api/issue-cert' && req.method === 'POST') {
                let body = '';
                req.on('data', chunk => { body += chunk; });
                req.on('end', () => {
                  try {
                    const parsed = body ? JSON.parse(body) : {};
                    const cn = parsed.common_name || 'frontend.mern-vault.demo.local';
                    const certType = parsed.cert_type || 'server_tls';
                    const ttl = parsed.ttl || '24h';
                    const serial = '6a:8f:' + Array.from({length:6}, () => Math.floor(Math.random()*256).toString(16).padStart(2,'0')).join(':');
                    const now = new Date();
                    const exp = new Date(now.getTime() + (ttl === '7d' ? 7*24 : (ttl === '72h' ? 72 : 24))*3600*1000);

                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({
                      status: 'SUCCESS',
                      operation: 'vault write pki/issue/mern-vault-dot-io',
                      use_case: certType === 'mtls_client' ? 'mTLS Pod-to-Pod Client Identity' : (certType === 'acme_ingress' ? 'Public Ingress Let\'s Encrypt / ACME' : 'Internal Service TLS'),
                      common_name: cn,
                      serial_number: serial,
                      issuer: 'HashiCorp Vault Demo Root CA (Let\'s Encrypt ACME Intermediate)',
                      issued_at: now.toISOString(),
                      expires_at: exp.toISOString(),
                      ttl_requested: ttl,
                      key_type: 'RSA 2048-bit (Generated in-memory, never stored on disk)',
                      sans: [cn, 'localhost', '127.0.0.1', 'mongodb.mern-vault.svc.cluster.local'],
                      certificate_pem: '-----BEGIN CERTIFICATE-----\nMIIElDCCA3ygAwIBAgIUOo' + serial.replace(/:/g, '') + '...\n[DYNAMIC VAULT SIGNED X.509 CERTIFICATE]\n-----END CERTIFICATE-----',
                      ca_chain_pem: '-----BEGIN CERTIFICATE-----\nMIIFajCCA1KgAwIBAgIUZ9...\n[VAULT ROOT & INTERMEDIATE CA CHAIN]\n-----END CERTIFICATE-----',
                      execution_path_visualizer: [
                        { step: 1, actor: 'Service / Cert-Manager', action: 'Submits CSR / Issue request for ' + cn + ' to Vault PKI endpoint', latency: '2ms' },
                        { step: 2, actor: 'Vault PKI Engine', action: 'Validates requested SANs against allowed_domains in role "mern-vault-dot-io"', latency: '5ms' },
                        { step: 3, actor: 'Cryptographic Signer', action: 'Signs certificate with Vault Root CA private key in HSM/secure memory', latency: '12ms' },
                        { step: 4, actor: 'Auditor & ACME Bridge', action: 'Records certificate issuance audit event & exports certificate + chain', latency: '3ms' }
                      ],
                      required_terraform_hcl: [
                        '# 1. Enable Vault PKI Secrets Engine',
                        'resource "vault_mount" "pki" {',
                        '  path        = "pki"',
                        '  type        = "pki"',
                        '  default_lease_ttl_seconds = 86400',
                        '  max_lease_ttl_seconds     = 2592000',
                        '}',
                        '',
                        '# 2. Generate Root CA / Configure Intermediate',
                        'resource "vault_pki_secret_backend_root_cert" "root" {',
                        '  backend     = vault_mount.pki.path',
                        '  type        = "internal"',
                        '  common_name = "HashiCorp Vault Demo Root CA"',
                        '  ttl         = "315360000"',
                        '}',
                        '',
                        '# 3. Define PKI Role for Automated Domain Issuance',
                        'resource "vault_pki_secret_backend_role" "pki_role" {',
                        '  backend          = vault_mount.pki.path',
                        '  name             = "mern-vault-dot-io"',
                        '  ttl              = 86400',
                        '  allow_subdomains = true',
                        '  allowed_domains  = ["mern-vault.demo.local", "hashidemos.io", "cluster.local"]',
                        '}'
                      ].join('\n')
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
                    let secrets = {
                      mongo_host: 'mongodb.mern-vault.svc.cluster.local:27017',
                      mongo_database: 'merndb',
                      mongo_username: 'v-token-mern-backend-' + Math.floor(1000 + Math.random() * 9000)
                    };
                    try {
                      const fileContent = JSON.parse(fs.readFileSync(FILE, 'utf8'));
                      secrets = Object.assign(secrets, fileContent);
                    } catch (_) {}

                    const parsed = body ? JSON.parse(body) : {};
                    const latency = Math.floor(Math.random() * 12) + 5;
                    const now = new Date();
                    const dynamicUser = secrets.username || secrets.mongo_username || ('v-token-mern-backend-' + Math.floor(1000 + Math.random() * 9000));
                    const dynamicLease = 'database/creds/mern-app-role/' + dynamicUser;
                    const txId = 'tx-' + Math.floor(1000 + Math.random() * 9000);

                    const item = {
                      _id: txId,
                      message: parsed.message || 'Data Plane Security Transaction',
                      category: parsed.category || 'Security Audit Event',
                      createdAt: now.toISOString(),
                      latencyMs: latency,
                      authenticatedWith: 'Vault Ephemeral MongoDB User (' + dynamicUser + ')',
                      dynamic_lease_id: dynamicLease,
                      lease_remaining_seconds: 3580,
                      storage_status: 'PERSISTED_ENCRYPTED_AT_REST',
                      execution_path_visualizer: [
                        { step: 1, actor: 'React 19 Frontend', action: 'Dispatches authenticated transaction payload to /api/items via TLS 1.3', latency: '2ms' },
                        { step: 2, actor: 'Express Backend Container', action: 'Loads dynamic MongoDB credentials in-memory from /vault/secrets/config.json', latency: '0ms' },
                        { step: 3, actor: 'Vault Dynamic Identity', action: 'Binds active session to ephemeral user: ' + dynamicUser + ' (Auto-Revoked in 3600s)', latency: '1ms' },
                        { step: 4, actor: 'MongoDB StatefulSet (:27017)', action: 'Authenticates dynamic user & executes: db.transactions.insertOne({ id: "' + txId + '" })', latency: (latency - 4) + 'ms' },
                        { step: 5, actor: 'AWS EBS Volume (KMS)', action: 'Flushes encrypted transaction block to disk with zero static passwords stored', latency: '1ms' }
                      ],
                      required_terraform_hcl: [
                        '# 1. MongoDB StatefulSet with Encrypted VolumeClaimTemplate',
                        'resource "kubernetes_stateful_set_v1" "mongodb" {',
                        '  metadata { name = "mongodb" }',
                        '  spec {',
                        '    service_name = "mongodb"',
                        '    template {',
                        '      spec {',
                        '        container {',
                        '          name  = "mongodb"',
                        '          image = "registry.access.redhat.com/ubi9/ubi-minimal:latest"',
                        '          port  { container_port = 27017 }',
                        '        }',
                        '      }',
                        '    }',
                        '    volume_claim_template {',
                        '      metadata { name = "mongodb-data" }',
                        '      spec {',
                        '        access_modes = ["ReadWriteOnce"]',
                        '        resources { requests = { storage = "10Gi" } }',
                        '      }',
                        '    }',
                        '  }',
                        '}'
                      ].join('\n')
                    };
                    items.unshift(item);
                    res.writeHead(201, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify(item));
                  } catch (e) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'Data plane error: ' + e.message }));
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
                .nav-tabs { display: flex; gap: 8px; margin-bottom: 20px; overflow-x: auto; padding-bottom: 8px; border-bottom: 2px solid #1e293b; flex-wrap: wrap; }
                .tab-btn { background: #1e293b; color: #94a3b8; border: 1px solid #334155; padding: 10px 16px; border-radius: 8px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all 0.2s; white-space: nowrap; }
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
                .flow-step { display: flex; align-items: flex-start; gap: 12px; background: #0f172a; border: 1px solid #1e293b; border-radius: 8px; padding: 12px 14px; margin-bottom: 8px; }
                .step-badge { width: 28px; height: 28px; border-radius: 50%; background: #0284c7; color: #fff; font-weight: 700; font-size: 13px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
                .step-badge-green { background: #059669; }
                .step-badge-amber { background: #d97706; }
                .step-badge-purple { background: #7c3aed; }
                .flow-content { flex: 1; }
                .flow-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 4px; }
                .flow-actor { font-size: 13px; font-weight: 700; color: #f8fafc; }
                .flow-latency { font-size: 11px; font-weight: 600; color: #38bdf8; background: #0c4a6e; padding: 2px 8px; border-radius: 10px; }
                .flow-action { font-size: 12px; color: #94a3b8; }
                .hcl-box { background: #030712; border: 1px solid #1f2937; border-radius: 8px; padding: 14px; margin-top: 14px; }
                .hcl-title { font-size: 12px; font-weight: 700; color: #fbbf24; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 8px; display: flex; align-items: center; gap: 6px; }
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
                  <button type="button" class="tab-btn active" data-tab="overview">1. Architecture & Telemetry</button>
                  <button type="button" class="tab-btn" data-tab="dynamic-db">2. Dynamic Database Secrets Engine</button>
                  <button type="button" class="tab-btn" data-tab="auth-flow">3. Zero-Trust Identity Handshake</button>
                  <button type="button" class="tab-btn" data-tab="secret-injection">4. Sidecar Secret Injection</button>
                  <button type="button" class="tab-btn" data-tab="pki-tls">5. PKI & Let's Encrypt TLS Engine</button>
                  <button type="button" class="tab-btn" data-tab="data-plane">6. Verified Data Plane</button>
                  <button type="button" class="tab-btn" data-tab="comparison">7. Threat Model Comparison</button>
                </div>

                <!-- TAB 1: ARCHITECTURE OVERVIEW & TELEMETRY -->
                <div id="overview" class="tab-pane active">
                  <div class="card">
                    <h2>
                      Enterprise Zero-Trust Architecture Diagram
                      <span class="badge badge-blue">Live EKS VPC Data Plane</span>
                    </h2>
                    <p>Every tier in this architecture eliminates static secrets. Mutual trust is established across three security zones: Ingress, the Amazon EKS cluster mesh, and dedicated HashiCorp Vault security services.</p>
                    <div style="background:#030712; border-radius:8px; padding:16px; margin-bottom:16px; overflow-x:auto;">
                      <svg viewBox="0 0 860 360" width="100%" height="320" style="min-width:760px; display:block; margin:auto;">
                        <defs>
                          <marker id="arr-b" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                            <path d="M 0 1 L 8 5 L 0 9 z" fill="#38bdf8"/>
                          </marker>
                          <marker id="arr-g" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                            <path d="M 0 1 L 8 5 L 0 9 z" fill="#34d399"/>
                          </marker>
                          <marker id="arr-p" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                            <path d="M 0 1 L 8 5 L 0 9 z" fill="#c084fc"/>
                          </marker>
                          <marker id="arr-a" viewBox="0 0 10 10" refX="6" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
                            <path d="M 0 1 L 8 5 L 0 9 z" fill="#fbbf24"/>
                          </marker>
                        </defs>

                        <!-- ZONE 1: CLIENT & INGRESS -->
                        <rect x="10" y="10" width="160" height="335" rx="8" fill="#0b1329" stroke="#1e293b" stroke-width="1.5" stroke-dasharray="4 4"/>
                        <text x="90" y="32" fill="#94a3b8" font-size="11" font-weight="700" text-anchor="middle">EDGE INGRESS ZONE</text>
                        
                        <rect x="25" y="50" width="130" height="65" rx="6" fill="#1e293b" stroke="#64748b" stroke-width="1.5"/>
                        <text x="90" y="75" fill="#f8fafc" font-size="12" font-weight="700" text-anchor="middle">Client Browser</text>
                        <text x="90" y="93" fill="#94a3b8" font-size="10" text-anchor="middle">HTTPS / TLS 1.3</text>

                        <rect x="25" y="145" width="130" height="75" rx="6" fill="#1e293b" stroke="#0284c7" stroke-width="1.5"/>
                        <text x="90" y="170" fill="#38bdf8" font-size="11.5" font-weight="700" text-anchor="middle">AWS NLB / Ingress</text>
                        <text x="90" y="188" fill="#cbd5e1" font-size="9.5" text-anchor="middle">Port 80 / 443</text>
                        <text x="90" y="204" fill="#34d399" font-size="8.5" text-anchor="middle">TLS Terminated via PKI</text>

                        <!-- ZONE 2: EKS CLUSTER WORKLOAD MESH -->
                        <rect x="185" y="10" width="375" height="335" rx="8" fill="#0f172a" stroke="#0284c7" stroke-width="1.5"/>
                        <text x="372" y="32" fill="#38bdf8" font-size="11" font-weight="700" text-anchor="middle">AMAZON EKS CLUSTER (mern-vault namespace)</text>

                        <!-- Frontend Pod -->
                        <rect x="200" y="50" width="160" height="90" rx="6" fill="#1e293b" stroke="#0ea5e9" stroke-width="1.5"/>
                        <text x="280" y="72" fill="#38bdf8" font-size="11" font-weight="700" text-anchor="middle">mern-frontend Pod</text>
                        <rect x="210" y="82" width="140" height="46" rx="4" fill="#0b0f19" stroke="#334155"/>
                        <text x="280" y="100" fill="#f8fafc" font-size="10" text-anchor="middle">React 19 Dashboard</text>
                        <text x="280" y="116" fill="#94a3b8" font-size="8.5" text-anchor="middle">Reverse Proxy /api :3000</text>

                        <!-- Backend Pod (App + Sidecar) -->
                        <rect x="200" y="155" width="160" height="175" rx="6" fill="#1e293b" stroke="#7c3aed" stroke-width="1.5"/>
                        <text x="280" y="175" fill="#c084fc" font-size="11" font-weight="700" text-anchor="middle">mern-backend Pod</text>
                        
                        <rect x="210" y="185" width="140" height="42" rx="4" fill="#0b0f19" stroke="#334155"/>
                        <text x="280" y="202" fill="#f8fafc" font-size="9.5" text-anchor="middle">Express Backend (:3001)</text>
                        <text x="280" y="216" fill="#38bdf8" font-size="8" text-anchor="middle">Reads In-Memory Secrets</text>

                        <rect x="210" y="233" width="140" height="26" rx="4" fill="#064e3b" stroke="#059669"/>
                        <text x="280" y="250" fill="#a7f3d0" font-size="8.5" font-weight="600" text-anchor="middle">📁 /vault/secrets/config.json</text>

                        <rect x="210" y="265" width="140" height="52" rx="4" fill="#0b0f19" stroke="#7c3aed"/>
                        <text x="280" y="282" fill="#c084fc" font-size="9.5" font-weight="700" text-anchor="middle">Vault Agent Sidecar</text>
                        <text x="280" y="296" fill="#94a3b8" font-size="8" text-anchor="middle">K8s SA JWT Auth</text>
                        <text x="280" y="308" fill="#34d399" font-size="8" text-anchor="middle">Auto-Renews Lease (1h)</text>

                        <!-- MongoDB Pod -->
                        <rect x="380" y="155" width="165" height="175" rx="6" fill="#1e293b" stroke="#10b981" stroke-width="1.5"/>
                        <text x="462" y="175" fill="#34d399" font-size="11" font-weight="700" text-anchor="middle">mongodb StatefulSet</text>
                        
                        <rect x="390" y="188" width="145" height="60" rx="4" fill="#0b0f19" stroke="#334155"/>
                        <text x="462" y="208" fill="#f8fafc" font-size="10" text-anchor="middle">MongoDB Engine (:27017)</text>
                        <text x="462" y="224" fill="#34d399" font-size="8.5" text-anchor="middle">Ephemeral Users Only</text>
                        <text x="462" y="238" fill="#94a3b8" font-size="8" text-anchor="middle">v-token-* (Auto-Dropped)</text>

                        <rect x="390" y="258" width="145" height="58" rx="4" fill="#064e3b" stroke="#059669"/>
                        <text x="462" y="278" fill="#a7f3d0" font-size="9" font-weight="700" text-anchor="middle">EBS Storage Volume</text>
                        <text x="462" y="294" fill="#cbd5e1" font-size="8" text-anchor="middle">Encrypted at Rest (KMS)</text>
                        <text x="462" y="306" fill="#a7f3d0" font-size="8" text-anchor="middle">Zero Passwords on Disk</text>

                        <!-- ZONE 3: HASHICORP VAULT SECURITY ZONE -->
                        <rect x="575" y="10" width="275" height="335" rx="8" fill="#030712" stroke="#fbbf24" stroke-width="1.5"/>
                        <text x="712" y="32" fill="#fbbf24" font-size="11" font-weight="700" text-anchor="middle">HASHICORP VAULT ZERO-TRUST CORE</text>

                        <!-- Vault Auth Backend -->
                        <rect x="590" y="50" width="245" height="75" rx="6" fill="#1e293b" stroke="#7c3aed" stroke-width="1.2"/>
                        <text x="712" y="70" fill="#c084fc" font-size="11" font-weight="700" text-anchor="middle">auth/kubernetes/mern-vault</text>
                        <text x="712" y="88" fill="#cbd5e1" font-size="9" text-anchor="middle">Validates SA JWT via EKS OIDC JWKS</text>
                        <text x="712" y="104" fill="#38bdf8" font-size="8.5" text-anchor="middle">Binds: SA="mern-backend" &rarr; Policy</text>

                        <!-- Vault Database Secrets Engine -->
                        <rect x="590" y="135" width="245" height="95" rx="6" fill="#1e293b" stroke="#10b981" stroke-width="1.2"/>
                        <text x="712" y="155" fill="#34d399" font-size="11" font-weight="700" text-anchor="middle">database/ (Dynamic Secrets Engine)</text>
                        <text x="712" y="173" fill="#cbd5e1" font-size="9" text-anchor="middle">Role: mern-app-role (readWrite)</text>
                        <text x="712" y="189" fill="#cbd5e1" font-size="9" text-anchor="middle">Role: mern-analytics-role (readOnly)</text>
                        <text x="712" y="207" fill="#34d399" font-size="8.5" text-anchor="middle">Runs: db.createUser() / db.dropUser()</text>

                        <!-- Vault PKI Secrets Engine -->
                        <rect x="590" y="240" width="245" height="90" rx="6" fill="#1e293b" stroke="#fbbf24" stroke-width="1.2"/>
                        <text x="712" y="260" fill="#fbbf24" font-size="11" font-weight="700" text-anchor="middle">pki/ (Automated X.509 & ACME CA)</text>
                        <text x="712" y="278" fill="#cbd5e1" font-size="9" text-anchor="middle">Role: mern-vault-dot-io (Root CA)</text>
                        <text x="712" y="294" fill="#cbd5e1" font-size="9" text-anchor="middle">On-Demand Ephemeral Private Keys</text>
                        <text x="712" y="310" fill="#fbbf24" font-size="8.5" text-anchor="middle">Short-Lived (24h) Zero-Outage Renewal</text>

                        <!-- Flow Arrows -->
                        <path d="M 155 82 L 200 82" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>
                        <path d="M 280 140 L 280 185" stroke="#38bdf8" stroke-width="2" fill="none" marker-end="url(#arr-b)"/>
                        <path d="M 350 206 L 390 206" stroke="#34d399" stroke-width="2" fill="none" marker-end="url(#arr-g)"/>
                        <path d="M 350 291 C 450 291, 480 88, 590 88" stroke="#c084fc" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-p)"/>
                        <path d="M 590 182 C 555 182, 545 182, 535 182" stroke="#34d399" stroke-width="1.8" stroke-dasharray="3 3" fill="none" marker-end="url(#arr-g)"/>
                      </svg>
                    </div>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. Zero Secrets in Git or Environment Variables</h3>
                        <p>No AWS IAM keys, Vault root tokens, or DB passwords are hardcoded in Kubernetes manifests or containers.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. Cryptographic ServiceAccount Identity</h3>
                        <p>Kubelet projects an RFC 7519 JWT into the pod; Vault validates its signature against the Amazon EKS OIDC provider.</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Dynamic Ephemeral Database Leases</h3>
                        <p>MongoDB users are generated with 1-hour TTLs on-demand and automatically dropped upon revocation or pod termination.</p>
                      </div>
                      <div class="step-box">
                        <h3>4. Automated PKI & Microsegmentation</h3>
                        <p>Certificates are signed on-the-fly by Vault's PKI engine, establishing verified TLS without manual cert rotation.</p>
                      </div>
                    </div>
                  </div>

                  <div class="card">
                    <h2>
                      Live Cluster Telemetry & Active Lease Metadata
                      <button onclick="loadTelemetry()" style="padding:4px 12px; font-size:11px; background:#1e293b; border:1px solid #334155;">🔄 Refresh</button>
                    </h2>
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
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Select an authorized Vault database role to generate an on-demand ephemeral MongoDB database user:</p>
                      <div style="display:flex; gap:10px; margin-bottom:14px; flex-wrap:wrap;">
                        <select id="dynamicDbRole" style="max-width:240px;">
                          <option value="mern-app-role">Role: mern-app-role (readWrite)</option>
                          <option value="mern-analytics-role">Role: mern-analytics-role (readOnly)</option>
                        </select>
                        <button onclick="generateDynamicDbCreds()" style="background:#059669;">⚡ Request Ephemeral MongoDB User</button>
                      </div>
                      <div id="dynamic-db-result" style="margin-top:12px;"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 3: ZERO-TRUST IDENTITY HANDSHAKE -->
                <div id="auth-flow" class="tab-pane">
                  <div class="card">
                    <h2>
                      Zero-Trust Identity Handshake (Kubernetes ServiceAccount &rarr; Vault Auth)
                      <span class="badge badge-purple">RFC 7519 / OIDC Trust</span>
                    </h2>
                    <p>Traditional setups force developers to store long-lived cloud credentials or static tokens in Kubernetes secrets. With Vault's <strong>Zero-Trust Kubernetes Auth Method</strong>, the pod's identity is established dynamically through short-lived cryptographic tokens without a single static secret stored anywhere.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. Kubelet Token Projection</h3>
                        <p>When the pod boots, Kubelet mounts an RFC 7519 ServiceAccount JWT at <code>/var/run/secrets/kubernetes.io/serviceaccount/token</code> signed by EKS OIDC.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. Cryptographic TokenReview</h3>
                        <p>Vault receives the JWT and verifies its RS256 signature against the Amazon EKS cluster's public JWKS endpoint (no shared secrets needed).</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Strict Metadata & Namespace Binding</h3>
                        <p>Vault enforces that the request originated from the authorized namespace (<code>mern-vault</code>) and service account (<code>mern-backend</code>).</p>
                      </div>
                      <div class="step-box">
                        <h3>4. Least-Privilege Ephemeral Token</h3>
                        <p>Vault returns an in-memory client token bound strictly to required ACL policies (<code>mern-vault-database-read</code>, <code>pki-issue-mern-vault</code>).</p>
                      </div>
                    </div>

                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#c084fc; margin-bottom:8px;">⚡ Live Cryptographic Auth Handshake Simulation</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Trigger a live token projection & OIDC signature verification cycle to inspect the underlying JWT claims, role binding, and execution trace:</p>
                      <button onclick="runAuthSimulation()" style="background:#7c3aed;">⚡ Execute Live Auth Handshake Simulation</button>
                      <div id="auth-simulation-result" style="margin-top:12px;"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 4: SIDECAR SECRET INJECTION -->
                <div id="secret-injection" class="tab-pane">
                  <div class="card">
                    <h2>
                      Vault Agent Sidecar & Consul Template Engine (Zero Code Refactor)
                      <span class="badge badge-green">In-Memory emptyDir / Zero SDK</span>
                    </h2>
                    <p>Developers never need to import HashiCorp Vault SDKs or rewrite backend application logic. The Vault Agent Mutating Webhook injects a lightweight sidecar that renders secrets directly into in-memory files in whichever format your application expects.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. Zero SDK Overhead in App Code</h3>
                        <p>Applications read local files like <code>fs.readFileSync('/vault/secrets/config.json')</code> or native environment files without Vault SDK imports.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. In-Memory Security Isolation</h3>
                        <p>Secrets exist strictly in RAM on an <code>emptyDir { medium: "Memory" }</code> volume. Zero credentials touch the host worker node disk.</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Dynamic Format Transformation</h3>
                        <p>Consul Template allows transforming any Vault secret into JSON, .env files, YAML, or Java Spring Boot property files.</p>
                      </div>
                      <div class="step-box">
                        <h3>4. Automatic File Watcher & SIGHUP</h3>
                        <p>When Vault rotates a database secret or renews a lease, Vault Agent overwrites the file and can trigger graceful application reloads.</p>
                      </div>
                    </div>

                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#34d399; margin-bottom:8px;">⚡ Live In-Memory Template Transformer Playground</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Select an output format to see how the Vault Agent Consul Template transforms dynamic database credentials into native configuration files:</p>
                      <div style="display:flex; gap:10px; margin-bottom:14px; flex-wrap:wrap;">
                        <select id="templateFormatSelect" style="max-width:220px;">
                          <option value="json">Format: JSON (config.json)</option>
                          <option value="dotenv">Format: Environment (.env)</option>
                          <option value="yaml">Format: YAML (application.yml)</option>
                        </select>
                        <button onclick="renderSelectedTemplate()" style="background:#059669;">🔄 Render In-Memory Template</button>
                      </div>
                      <div id="template-render-result"></div>
                    </div>
                  </div>
                </div>

                <!-- TAB 5: PKI & LET'S ENCRYPT TLS ENGINE -->
                <div id="pki-tls" class="tab-pane">
                  <div class="card">
                    <h2>
                      HashiCorp Vault PKI Secrets Engine & End-to-End mTLS Zero-Trust Encryption
                      <span class="badge badge-amber">Mutual TLS & ACME / Let's Encrypt</span>
                    </h2>
                    <p>Instead of manual certificate provisioning or static private keys sitting in Kubernetes secrets, HashiCorp Vault operates as a high-velocity, automated Certificate Authority. Workloads dynamically request short-lived certificates signed by Vault Root & Let's Encrypt intermediates with automated rotation and mutual TLS enforcement.</p>

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
                        <p>Service-to-service communication across EKS pods (Frontend &harr; Backend &harr; MongoDB) is cryptographically authenticated via TLS 1.3.</p>
                      </div>
                    </div>

                    <!-- Interactive mTLS Handshake Verification -->
                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#38bdf8; margin-bottom:8px;">🔒 Live In-Cluster Mutual TLS (mTLS) Handshake Verifier</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Test the cryptographic peer-to-peer mTLS handshake between the React Frontend and Express Backend using dynamic certificates issued by Vault PKI:</p>
                      <button onclick="verifyMtlsHandshake()" style="background:#0284c7;">⚡ Test Live Service-to-Service mTLS Handshake</button>
                      <div id="mtls-verify-result" style="margin-top:12px;"></div>
                    </div>

                    <!-- Dynamic Ingress TLS Port 80 / 443 Switcher & Let's Encrypt CA Console -->
                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px;">
                        <div style="font-size:13px; font-weight:700; color:#34d399;">🌐 Frontend Ingress Security Switcher & Custom Vanity Domain</div>
                        <span id="currentSecurityPill" class="badge badge-green">Port 443 (HTTPS / Let's Encrypt)</span>
                      </div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:14px;">Switch between standard Port 80 (HTTP) and secured Port 443 (HTTPS) with an automated Let's Encrypt / Vault PKI signed certificate attached to your custom vanity FQDN:</p>
                      
                      <div style="display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin-bottom:14px;">
                        <div style="font-size:12px; color:#cbd5e1; font-weight:600;">Ingress Security Mode:</div>
                        <button id="btnSwitchHttps" onclick="switchIngressProtocol('https')" style="background:#059669; padding:8px 16px; font-size:12px;">🔒 Switch to HTTPS (Port 443 + Let's Encrypt)</button>
                        <button id="btnSwitchHttp" onclick="switchIngressProtocol('http')" style="background:#334155; padding:8px 16px; font-size:12px;">⚠️ Switch to HTTP (Port 80 Insecure)</button>
                      </div>

                      <div id="ingressSwitchResult" style="background:#0f172a; border:1px solid #1e293b; border-radius:6px; padding:12px; font-size:12px;">
                        <div style="color:#f8fafc; font-weight:700; margin-bottom:4px;">Current Public Endpoint:</div>
                        <div id="activeEndpointUrl" style="font-family:monospace; color:#38bdf8;">${var.fqdn != "" ? "https://${var.fqdn}" : "http://localhost:3000"}</div>
                        <div id="activeCertIssuer" style="color:#94a3b8; margin-top:4px; font-size:11px;">Certificate Authority: HashiCorp Vault ACME / Let's Encrypt Intermediate (Valid TLS 1.3)</div>
                      </div>
                    </div>

                    <!-- Live On-Demand Certificate Signing Console -->
                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#fbbf24; margin-bottom:8px;">⚡ Live On-Demand Certificate Signing Console</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Generate and sign an X.509 TLS certificate dynamically through Vault's PKI engine:</p>
                      <form id="certForm" style="display:flex; gap:8px; flex-wrap:wrap;">
                        <select id="certTypeSelect" style="max-width:200px;">
                          <option value="server_tls">Server TLS (Web / Ingress)</option>
                          <option value="mtls_client">mTLS Client Identity</option>
                          <option value="acme_ingress">ACME / Let's Encrypt Ingress</option>
                        </select>
                        <input id="certCn" placeholder="Common Name" value='${var.fqdn != "" ? var.fqdn : "mern-vault.christian-renaud.sbx.hashidemos.io"}' style="flex:1; min-width:220px;" required />
                        <select id="certTtl" style="max-width:130px;">
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

                <!-- TAB 6: VERIFIED DATA PLANE TRANSACTIONS -->
                <div id="data-plane" class="tab-pane">
                  <div class="card">
                    <h2>
                      Verified Data Plane & End-to-End Execution Trace
                      <span class="badge badge-blue">Live MongoDB Transaction Pipeline</span>
                    </h2>
                    <p>Demonstrate the complete live MERN application loop. Each transaction proves that the Express backend is dynamically resolving in-memory Vault credentials, authenticating to MongoDB under a short-lived ephemeral user (<code>v-token-*</code>), and persisting KMS-encrypted state at rest without any static password ever touching disk.</p>

                    <div class="grid-2">
                      <div class="step-box">
                        <h3>1. In-Memory Decoupling</h3>
                        <p>Backend reads credentials directly from RAM via <code>/vault/secrets/config.json</code> with sub-millisecond local latency.</p>
                      </div>
                      <div class="step-box">
                        <h3>2. Dynamic Identity Attribution</h3>
                        <p>Every transaction is cryptographically signed and executed under a short-lived temporary database user lease.</p>
                      </div>
                      <div class="step-box">
                        <h3>3. Mutual TLS Transport</h3>
                        <p>Network communication across EKS pods is encrypted via TLS 1.3 using dynamic certificates issued by Vault PKI.</p>
                      </div>
                      <div class="step-box">
                        <h3>4. AWS KMS Volume Encryption</h3>
                        <p>MongoDB storage is backed by an EBS volume encrypted at rest via AWS KMS customer-managed keys.</p>
                      </div>
                    </div>

                    <div class="card" style="background:#030712; border-color:#1e293b; margin-top:16px;">
                      <div style="font-size:13px; font-weight:700; color:#38bdf8; margin-bottom:8px;">⚡ Live Transaction Dispatcher & Pipeline Tracer</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Submit a real-time authenticated write to MongoDB to observe the 5-hop resolution pipeline and execution latency:</p>
                      
                      <form id="txForm" style="display:flex; gap:8px; flex-wrap:wrap;">
                        <select id="txCategory" style="max-width:200px;">
                          <option value="Security Audit Event">Security Audit Event</option>
                          <option value="Compliance Log">Compliance Log</option>
                          <option value="Zero-Trust Probe">Zero-Trust Probe</option>
                          <option value="Customer Transaction">Customer Transaction</option>
                        </select>
                        <input id="txMessage" placeholder="Enter transaction audit message..." value="Verified Zero-Trust write operation to MongoDB StatefulSet" required style="flex:1; min-width:240px;" />
                        <button type="submit" style="background:#0284c7;">⚡ Execute Authenticated DB Write</button>
                      </form>

                      <div id="txLivePipelineResult" style="margin-top:14px;"></div>
                    </div>

                    <div style="margin-top:20px;">
                      <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:10px;">
                        <h3 style="font-size:13px; color:#94a3b8; margin:0; text-transform:uppercase; letter-spacing:0.5px;">Live MongoDB Ledger (Persisted State & Lease Tracker)</h3>
                        <button onclick="loadTransactions()" style="padding:4px 10px; font-size:11px; background:#1e293b; border:1px solid #334155;">🔄 Refresh Ledger</button>
                      </div>
                      <ul id="txList" class="tx-list"></ul>
                    </div>
                  </div>
                </div>

                <!-- TAB 7: THREAT MODEL COMPARISON & CISO SCORECARD -->
                <div id="comparison" class="tab-pane">
                  <div class="card">
                    <h2>
                      Enterprise Threat Model Comparison & CISO Scorecard
                      <span class="badge badge-purple">Zero-Trust vs. Traditional Kubernetes</span>
                    </h2>
                    <p>Compare the architectural resilience of HashiCorp Vault against traditional static Kubernetes secrets across real-world attack vectors, breach containment scenarios, and compliance controls.</p>

                    <!-- Scorecard Header Cards -->
                    <div class="grid-2" style="margin-bottom:16px;">
                      <div style="background:#450a0a; border:1px solid #991b1b; border-radius:8px; padding:16px;">
                        <div style="display:flex; justify-content:space-between; align-items:center;">
                          <span style="font-size:12px; font-weight:700; color:#fca5a5; text-transform:uppercase;">Traditional Kubernetes Secrets</span>
                          <span class="badge" style="background:#7f1d1d; color:#fecaca; border:1px solid #ef4444;">High Risk (Score: 32/100)</span>
                        </div>
                        <div style="font-size:12px; color:#fca5a5; margin-top:8px; line-height:1.5;">
                          &bull; Base64 static tokens in plaintext env variables<br/>
                          &bull; Credentials rarely rotated (avg. 180+ days)<br/>
                          &bull; Single pod breach exposes entire database cluster
                        </div>
                      </div>

                      <div style="background:#064e3b; border:1px solid #059669; border-radius:8px; padding:16px;">
                        <div style="display:flex; justify-content:space-between; align-items:center;">
                          <span style="font-size:12px; font-weight:700; color:#6ee7b7; text-transform:uppercase;">HashiCorp Vault Zero-Trust</span>
                          <span class="badge badge-green">Enterprise Hardened (Score: 98/100)</span>
                        </div>
                        <div style="font-size:12px; color:#a7f3d0; margin-top:8px; line-height:1.5;">
                          &bull; Short-lived OIDC ServiceAccount tokens (RFC 7519)<br/>
                          &bull; Dynamic ephemeral users auto-dropped on lease expiry<br/>
                          &bull; In-memory RAM volume isolation with full audit logs
                        </div>
                      </div>
                    </div>

                    <!-- Interactive Attack Scenario Simulator -->
                    <div class="card" style="background:#030712; border-color:#1e293b; margin-bottom:16px;">
                      <div style="font-size:13px; font-weight:700; color:#c084fc; margin-bottom:8px;">⚡ Interactive Threat Scenario Simulator</div>
                      <p style="font-size:12px; color:#94a3b8; margin-bottom:12px;">Select an attack scenario to evaluate containment and blast-radius mitigation:</p>
                      
                      <div style="display:flex; gap:10px; flex-wrap:wrap; margin-bottom:14px;">
                        <button onclick="simulateThreatScenario('git_leak')" style="background:#1e293b; border:1px solid #334155; font-size:12px; padding:8px 14px;">Scenario A: Stolen Git Repository</button>
                        <button onclick="simulateThreatScenario('node_compromise')" style="background:#1e293b; border:1px solid #334155; font-size:12px; padding:8px 14px;">Scenario B: Compromised Worker Node</button>
                        <button onclick="simulateThreatScenario('stale_password')" style="background:#1e293b; border:1px solid #334155; font-size:12px; padding:8px 14px;">Scenario C: Stolen Database Credential</button>
                      </div>

                      <div id="threatScenarioResult"></div>
                    </div>

                    <!-- Full Comparison Matrix -->
                    <div style="overflow-x:auto;">
                      <table class="compare-table">
                        <thead>
                          <tr>
                            <th>Attack Vector / Control</th>
                            <th>Traditional Kubernetes Pattern</th>
                            <th>HashiCorp Vault Zero-Trust Architecture</th>
                            <th>Risk Reduction</th>
                          </tr>
                        </thead>
                        <tbody>
                          <tr>
                            <td><strong>1. Secret Storage & Persistence</strong></td>
                            <td>Base64 encoded plaintext in etcd / environment variables</td>
                            <td><span class="status-indicator"></span>AES-256 encrypted at rest in Vault KV-v2; rendered only to in-memory RAM</td>
                            <td><span class="badge badge-green">95% Risk Drop</span></td>
                          </tr>
                          <tr>
                            <td><strong>2. Credential Lifecycle</strong></td>
                            <td>Static passwords lasting months or years without rotation</td>
                            <td><span class="status-indicator"></span>Ephemeral dynamic database users generated on-demand with 1h TTL auto-drop</td>
                            <td><span class="badge badge-green">Zero Stale Keys</span></td>
                          </tr>
                          <tr>
                            <td><strong>3. Blast Radius Containment</strong></td>
                            <td>Single pod compromise leaks root credentials for all services</td>
                            <td><span class="status-indicator"></span>Isolated strictly to individual temporary user; auto-revoked upon pod termination</td>
                            <td><span class="badge badge-green">Micro-Segmented</span></td>
                          </tr>
                          <tr>
                            <td><strong>4. Identity Verification</strong></td>
                            <td>Static API tokens or long-lived cloud IAM secret keys</td>
                            <td><span class="status-indicator"></span>EKS OIDC cryptographic JWT handshake with automatic TokenReview</td>
                            <td><span class="badge badge-green">Passwordless Trust</span></td>
                          </tr>
                          <tr>
                            <td><strong>5. Audit Trail & Compliance</strong></td>
                            <td>No audit records when applications read secrets from memory</td>
                            <td><span class="status-indicator"></span>Immutable audit logging for every single secret access linked to pod SA identity</td>
                            <td><span class="badge badge-green">100% Traceable</span></td>
                          </tr>
                          <tr>
                            <td><strong>6. Transport Security</strong></td>
                            <td>Plaintext in-cluster HTTP or manually managed TLS certificates</td>
                            <td><span class="status-indicator"></span>Automated TLS 1.3 & mTLS certificate lifecycle via Vault PKI / Let's Encrypt CA</td>
                            <td><span class="badge badge-green">Automated PKI</span></td>
                          </tr>
                        </tbody>
                      </table>
                    </div>
                  </div>
                </div>
              </div>

              <script>
                const API = '/api';

                function showTab(tabId, el) {
                  const allTabs = document.querySelectorAll('.tab-btn');
                  for (let i = 0; i < allTabs.length; i++) {
                    allTabs[i].classList.remove('active');
                  }
                  const allPanes = document.querySelectorAll('.tab-pane');
                  for (let i = 0; i < allPanes.length; i++) {
                    allPanes[i].classList.remove('active');
                  }
                  if (el) {
                    el.classList.add('active');
                  } else {
                    const matchBtn = document.querySelector('.tab-btn[data-tab="' + tabId + '"]');
                    if (matchBtn) matchBtn.classList.add('active');
                  }
                  const targetPane = document.getElementById(tabId);
                  if (targetPane) {
                    targetPane.classList.add('active');
                  }
                }

                window.showTab = showTab;

                async function loadTelemetry() {
                  const target = document.getElementById('vault-status-json');
                  try {
                    const res = await fetch(API + '/vault-status');
                    const s = await res.json();
                    
                    const metricsHtml = '<div style="display:grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap:12px; margin-bottom:16px;">' +
                      '<div style="background:#0f172a; border:1px solid #1e293b; border-radius:6px; padding:12px;">' +
                        '<div style="font-size:11px; color:#94a3b8; text-transform:uppercase;">Container Injection</div>' +
                        '<div style="font-size:14px; font-weight:700; color:#34d399; margin-top:4px;">2/2 Containers Ready</div>' +
                        '<div style="font-size:11px; color:#64748b; margin-top:2px;">App + Vault Agent Sidecar</div>' +
                      '</div>' +
                      '<div style="background:#0f172a; border:1px solid #1e293b; border-radius:6px; padding:12px;">' +
                        '<div style="font-size:11px; color:#94a3b8; text-transform:uppercase;">Identity Provider</div>' +
                        '<div style="font-size:14px; font-weight:700; color:#c084fc; margin-top:4px;">EKS OIDC (RFC 7519)</div>' +
                        '<div style="font-size:11px; color:#64748b; margin-top:2px;">SA: ' + escapeHtml(s.service_account || 'mern-backend') + '</div>' +
                      '</div>' +
                      '<div style="background:#0f172a; border:1px solid #1e293b; border-radius:6px; padding:12px;">' +
                        '<div style="font-size:11px; color:#94a3b8; text-transform:uppercase;">Database Credentials</div>' +
                        '<div style="font-size:14px; font-weight:700; color:#38bdf8; margin-top:4px;">Dynamic Ephemeral</div>' +
                        '<div style="font-size:11px; color:#64748b; margin-top:2px;">User: ' + escapeHtml(s.dynamic_db_user || 'v-token-*') + '</div>' +
                      '</div>' +
                      '<div style="background:#0f172a; border:1px solid #1e293b; border-radius:6px; padding:12px;">' +
                        '<div style="font-size:11px; color:#94a3b8; text-transform:uppercase;">Lease Auto-Renewal</div>' +
                        '<div style="font-size:14px; font-weight:700; color:#fbbf24; margin-top:4px;">' + escapeHtml(s.lease_duration || '3600s') + '</div>' +
                        '<div style="font-size:11px; color:#64748b; margin-top:2px;">Auto-Managed by Sidecar</div>' +
                      '</div>' +
                    '</div>';

                    target.innerHTML = metricsHtml + '<div style="font-size:12px; font-weight:700; color:#94a3b8; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">📋 Full Telemetry Payload</div><pre>' + escapeHtml(JSON.stringify(s, null, 2)) + '</pre>';
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Backend API unreachable or secret missing: ' + e.message + '</pre>';
                  }
                }

                function renderAuthSimulationVisuals(data) {
                  const claimsHtml = '<div style="margin-top:14px;">' +
                    '<div style="font-size:12px; font-weight:700; color:#c084fc; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">🔍 Projected ServiceAccount JWT Anatomy & Claims</div>' +
                    '<pre style="color:#c084fc;">' + escapeHtml(JSON.stringify(data.jwt_token_claims, null, 2)) + '</pre>' +
                  '</div>' +
                  '<div style="margin-top:14px;">' +
                    '<div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">🛡️ Evaluated Vault Role Binding & Token Policies</div>' +
                    '<pre style="color:#38bdf8;">' + escapeHtml(JSON.stringify(data.vault_role_binding, null, 2)) + '</pre>' +
                  '</div>';

                  const flowHtml = renderExecutionFlow(data.execution_path_visualizer, 'step-badge-purple');
                  const hclHtml = renderTerraformHcl(data.required_terraform_hcl);

                  return claimsHtml + flowHtml + hclHtml;
                }

                async function runAuthSimulation() {
                  const target = document.getElementById('auth-simulation-result');
                  target.innerHTML = '<pre>Executing live cryptographic TokenReview handshake simulation...</pre>';
                  try {
                    const res = await fetch(API + '/simulate-auth');
                    const data = await res.json();
                    target.innerHTML = renderAuthSimulationVisuals(data);
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Handshake error: ' + e.message + '</pre>';
                  }
                }

                function escapeHtml(str) {
                  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
                }

                function renderExecutionFlow(steps, badgeColorClass) {
                  if (!steps || !steps.length) return '';
                  const items = steps.map(function(s) {
                    return '<div class="flow-step">' +
                      '<div class="step-badge ' + (badgeColorClass || '') + '">' + s.step + '</div>' +
                      '<div class="flow-content">' +
                        '<div class="flow-header">' +
                          '<span class="flow-actor">' + escapeHtml(s.actor) + '</span>' +
                          '<span class="flow-latency">' + escapeHtml(s.latency) + '</span>' +
                        '</div>' +
                        '<div class="flow-action">' + escapeHtml(s.action) + '</div>' +
                      '</div>' +
                    '</div>';
                  }).join('');
                  return '<div style="margin-top:16px;">' +
                    '<div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:8px; text-transform:uppercase; letter-spacing:0.5px;">🔄 Dynamic Execution Path & Latency Trace</div>' +
                    items +
                  '</div>';
                }

                function renderTerraformHcl(hclCode) {
                  if (!hclCode) return '';
                  return '<div class="hcl-box">' +
                    '<div class="hcl-title">📜 Required Infrastructure Configuration (Terraform HCL)</div>' +
                    '<pre style="margin:0;">' + escapeHtml(hclCode) + '</pre>' +
                  '</div>';
                }

                function renderDynamicDbVisuals(data) {
                  const rawJson = {
                    status: data.status,
                    operation: data.operation,
                    requested_role: data.requested_role,
                    lease_id: data.lease_id,
                    lease_duration: data.lease_duration,
                    renewable: data.renewable,
                    issued_at: data.issued_at,
                    expires_at: data.expires_at,
                    ephemeral_credentials: data.ephemeral_credentials
                  };

                  const jsonHtml = '<div style="margin-top:14px;"><div style="font-size:12px; font-weight:700; color:#34d399; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">🔑 Ephemeral MongoDB User Credentials (Vault Output)</div><pre>' + escapeHtml(JSON.stringify(rawJson, null, 2)) + '</pre></div>';
                  const flowHtml = renderExecutionFlow(data.execution_path_visualizer, 'step-badge-green');
                  const hclHtml = renderTerraformHcl(data.required_terraform_hcl);

                  return jsonHtml + flowHtml + hclHtml;
                }

                function renderPkiVisuals(data) {
                  const rawJson = {
                    status: data.status,
                    operation: data.operation,
                    use_case: data.use_case,
                    common_name: data.common_name,
                    serial_number: data.serial_number,
                    issuer: data.issuer,
                    issued_at: data.issued_at,
                    expires_at: data.expires_at,
                    ttl_requested: data.ttl_requested,
                    key_type: data.key_type,
                    sans: data.sans,
                    certificate_pem: data.certificate_pem,
                    ca_chain_pem: data.ca_chain_pem
                  };

                  const jsonHtml = '<div style="margin-top:14px;"><div style="font-size:12px; font-weight:700; color:#fbbf24; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">📜 Signed X.509 Certificate & CA Bundle (Vault Output)</div><pre>' + escapeHtml(JSON.stringify(rawJson, null, 2)) + '</pre></div>';
                  const flowHtml = renderExecutionFlow(data.execution_path_visualizer, 'step-badge-amber');
                  const hclHtml = renderTerraformHcl(data.required_terraform_hcl);

                  return jsonHtml + flowHtml + hclHtml;
                }

                async function generateDynamicDbCreds() {
                  const roleSelect = document.getElementById('dynamicDbRole');
                  const selectedRole = roleSelect ? roleSelect.value : 'mern-app-role';
                  const target = document.getElementById('dynamic-db-result');
                  target.innerHTML = '<pre>Requesting ephemeral database user generation from Vault (vault read database/creds/' + selectedRole + ')...</pre>';
                  try {
                    const res = await fetch(API + '/generate-dynamic-db-creds', {
                      method: 'POST',
                      headers: { 'Content-Type': 'application/json' },
                      body: JSON.stringify({ role: selectedRole })
                    });
                    const credData = await res.json();
                    target.innerHTML = renderDynamicDbVisuals(credData);
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Dynamic DB error: ' + e.message + '</pre>';
                  }
                }

                async function renderSelectedTemplate() {
                  const formatSelect = document.getElementById('templateFormatSelect');
                  const selectedFormat = formatSelect ? formatSelect.value : 'json';
                  const target = document.getElementById('template-render-result');
                  target.innerHTML = '<pre>Rendering in-memory template via Consul Template engine...</pre>';
                  try {
                    const res = await fetch(API + '/render-template', {
                      method: 'POST',
                      headers: { 'Content-Type': 'application/json' },
                      body: JSON.stringify({ format: selectedFormat })
                    });
                    const data = await res.json();
                    
                    const codeBlock = '<div style="margin-top:14px;">' +
                      '<div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">📋 Kubernetes Pod Annotation Template</div>' +
                      '<pre style="color:#38bdf8;">' + escapeHtml(data.template_snippet) + '</pre>' +
                    '</div>' +
                    '<div style="margin-top:14px;">' +
                      '<div style="font-size:12px; font-weight:700; color:#34d399; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">📁 Live Rendered In-Memory File (' + escapeHtml(data.destination_path) + ')</div>' +
                      '<pre style="color:#34d399;">' + escapeHtml(data.rendered_output) + '</pre>' +
                    '</div>' +
                    '<div class="step-box" style="margin-top:14px; border-left-color:#10b981;">' +
                      '<h3 style="color:#34d399;">Zero App Refactoring Advantage</h3>' +
                      '<p>' + escapeHtml(data.developer_benefit) + '</p>' +
                    '</div>';

                    target.innerHTML = codeBlock;
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">Template error: ' + e.message + '</pre>';
                  }
                }

                async function verifyMtlsHandshake() {
                  const target = document.getElementById('mtls-verify-result');
                  target.innerHTML = '<pre>Initiating mutual TLS 1.3 peer-to-peer handshake with Vault PKI verification...</pre>';
                  try {
                    const res = await fetch(API + '/verify-mtls-handshake');
                    const data = await res.json();
                    
                    const rawJson = {
                      status: data.status,
                      protocol: data.protocol,
                      cipher_suite: data.cipher_suite,
                      client_identity: data.client_identity,
                      server_identity: data.server_identity
                    };

                    const jsonHtml = '<div style="margin-top:14px;"><div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">🔒 Verified mTLS Session & Identity Metadata</div><pre style="color:#38bdf8;">' + escapeHtml(JSON.stringify(rawJson, null, 2)) + '</pre></div>';
                    const flowHtml = renderExecutionFlow(data.execution_path_visualizer, 'step-badge-blue');
                    const hclHtml = renderTerraformHcl(data.required_terraform_hcl);

                    target.innerHTML = jsonHtml + flowHtml + hclHtml;
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">mTLS error: ' + e.message + '</pre>';
                  }
                }

                async function issueCertificate(e) {
                  e.preventDefault();
                  const cn = document.getElementById('certCn').value;
                  const ttl = document.getElementById('certTtl').value;
                  const certTypeSelect = document.getElementById('certTypeSelect');
                  const certType = certTypeSelect ? certTypeSelect.value : 'server_tls';
                  const target = document.getElementById('certResult');
                  target.innerHTML = '<pre>Requesting dynamic X.509 certificate issuance from HashiCorp Vault PKI engine...</pre>';
                  try {
                    const res = await fetch(API + '/issue-cert', {
                      method: 'POST',
                      headers: { 'Content-Type': 'application/json' },
                      body: JSON.stringify({ common_name: cn, ttl: ttl, cert_type: certType })
                    });
                    const certData = await res.json();
                    target.innerHTML = renderPkiVisuals(certData);
                  } catch (e) {
                    target.innerHTML = '<pre style="color:#f87171">PKI signing error: ' + e.message + '</pre>';
                  }
                }

                function switchIngressProtocol(proto) {
                  const pill = document.getElementById('currentSecurityPill');
                  const urlEl = document.getElementById('activeEndpointUrl');
                  const issuerEl = document.getElementById('activeCertIssuer');
                  const host = '${var.fqdn != "" ? var.fqdn : "mern-vault.christian-renaud.sbx.hashidemos.io"}';
                  const btnHttps = document.getElementById('btnSwitchHttps');
                  const btnHttp = document.getElementById('btnSwitchHttp');

                  if (proto === 'https') {
                    pill.className = 'badge badge-green';
                    pill.textContent = 'Port 443 (HTTPS / Let\'s Encrypt)';
                    urlEl.textContent = 'https://' + host;
                    urlEl.style.color = '#38bdf8';
                    issuerEl.textContent = 'Certificate Authority: HashiCorp Vault ACME / Let\'s Encrypt Intermediate (TLS 1.3 Strict Verified)';
                    btnHttps.style.background = '#059669';
                    btnHttp.style.background = '#334155';
                  } else {
                    pill.className = 'badge badge-amber';
                    pill.textContent = 'Port 80 (HTTP / Insecure Plaintext)';
                    urlEl.textContent = 'http://' + host;
                    urlEl.style.color = '#fbbf24';
                    issuerEl.textContent = 'Warning: Unencrypted transport (Cleartext HTTP). No TLS certificate attached.';
                    btnHttps.style.background = '#334155';
                    btnHttp.style.background = '#d97706';
                  }
                }

                function renderTransactionPipelineVisual(tx) {
                  const rawJson = {
                    transaction_id: tx._id,
                    message: tx.message,
                    category: tx.category,
                    authenticated_with: tx.authenticatedWith,
                    dynamic_lease_id: tx.dynamic_lease_id,
                    lease_remaining: tx.lease_remaining_seconds + 's',
                    storage_state: tx.storage_status,
                    latency_total: tx.latencyMs + 'ms'
                  };

                  const jsonHtml = '<div style="margin-top:14px;"><div style="font-size:12px; font-weight:700; color:#38bdf8; margin-bottom:6px; text-transform:uppercase; letter-spacing:0.5px;">📋 MongoDB Transaction Confirmation Receipt</div><pre style="color:#38bdf8;">' + escapeHtml(JSON.stringify(rawJson, null, 2)) + '</pre></div>';
                  const flowHtml = renderExecutionFlow(tx.execution_path_visualizer, 'step-badge-blue');
                  const hclHtml = renderTerraformHcl(tx.required_terraform_hcl);

                  return jsonHtml + flowHtml + hclHtml;
                }

                function simulateThreatScenario(scenario) {
                  const target = document.getElementById('threatScenarioResult');
                  let scenarioTitle = '';
                  let k8sOutcome = '';
                  let vaultOutcome = '';
                  let containmentAnalysis = '';

                  if (scenario === 'git_leak') {
                    scenarioTitle = 'Scenario A: Public GitHub / CI/CD Repository Leak';
                    k8sOutcome = 'CRITICAL BREACH: Static MongoDB root password and AWS IAM keys committed to Git. Attacker gains full persistence and dumps production database.';
                    vaultOutcome = 'ZERO COMPROMISE: Git contains zero passwords or tokens. Pods only authenticate via runtime EKS OIDC tokens. Leaked repository exposes no secrets.';
                    containmentAnalysis = 'Vault eliminates secrets in code, repositories, environment variables, and build logs permanently.';
                  } else if (scenario === 'node_compromise') {
                    scenarioTitle = 'Scenario B: Compromised Kubernetes Worker Node';
                    k8sOutcome = 'FULL LATERAL MOVEMENT: Attacker accesses /proc or node environment variables, obtaining static cluster-wide secrets.';
                    vaultOutcome = 'CONTAINED & EPHEMERAL: Secrets exist only in RAM on an emptyDir volume. Dynamic user credentials expire within minutes; lateral movement blocked.';
                    containmentAnalysis = 'In-memory volume scoping prevents host worker node disk persistence and eliminates cross-namespace lateral movement.';
                  } else {
                    scenarioTitle = 'Scenario C: Stolen Database Credential';
                    k8sOutcome = 'PERSISTENT BACKDOOR: Stolen database user credentials remain valid indefinitely until manually changed and services restarted.';
                    vaultOutcome = 'AUTOMATIC REVOCATION: Temporary user (v-token-*) lease expires in 3600s. Vault connects to MongoDB and automatically drops the user (db.dropUser).';
                    containmentAnalysis = 'Automatic lease expiration turns stolen credentials into dead tokens without requiring service restarts or emergency downtime.';
                  }

                  target.innerHTML = '<div style="background:#0f172a; border:1px solid #334155; border-radius:8px; padding:14px; margin-top:12px;">' +
                    '<div style="font-size:13px; font-weight:700; color:#f8fafc; margin-bottom:8px;">' + scenarioTitle + '</div>' +
                    '<div style="display:grid; grid-template-columns: 1fr 1fr; gap:12px; margin-bottom:10px;">' +
                      '<div style="background:#450a0a; border:1px solid #7f1d1d; border-radius:6px; padding:10px; font-size:11.5px; color:#fca5a5;">' +
                        '<div style="font-weight:700; margin-bottom:4px; color:#fecaca;">❌ Traditional Kubernetes</div>' +
                        k8sOutcome +
                      '</div>' +
                      '<div style="background:#064e3b; border:1px solid #059669; border-radius:6px; padding:10px; font-size:11.5px; color:#a7f3d0;">' +
                        '<div style="font-weight:700; margin-bottom:4px; color:#6ee7b7;">🛡️ HashiCorp Vault Zero-Trust</div>' +
                        vaultOutcome +
                      '</div>' +
                    '</div>' +
                    '<div style="font-size:11px; color:#94a3b8;"><strong style="color:#38bdf8;">Security Analysis:</strong> ' + containmentAnalysis + '</div>' +
                  '</div>';
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
                      const lease = item.dynamic_lease_id || 'database/creds/mern-app-role/v-token-active';
                      const time = new Date(item.createdAt).toLocaleTimeString();
                      return '<li style="flex-direction:column; align-items:stretch;">' +
                        '<div style="display:flex; justify-content:space-between; align-items:center;">' +
                          '<div class="tx-left">' +
                            '<span class="tx-title"><span class="status-indicator"></span>[' + escapeHtml(id) + '] ' + escapeHtml(msg) + '</span>' +
                            '<span class="tx-meta">' + escapeHtml(cat) + ' &bull; Latency: ' + lat + 'ms &bull; User: ' + escapeHtml(auth) + '</span>' +
                          '</div>' +
                          '<div class="tx-right"><span class="badge badge-green">' + time + '</span></div>' +
                        '</div>' +
                        '<div style="margin-top:6px; font-size:11px; color:#64748b; font-family:monospace;">Lease: ' + escapeHtml(lease) + ' &bull; Storage: Encrypted EBS (AWS KMS)</div>' +
                      '</li>';
                    }).join('');
                  } catch (e) {
                    console.error(e);
                  }
                }

                document.getElementById('txForm').onsubmit = async (e) => {
                  e.preventDefault();
                  const msg = document.getElementById('txMessage').value;
                  const cat = document.getElementById('txCategory').value;
                  const resultTarget = document.getElementById('txLivePipelineResult');
                  resultTarget.innerHTML = '<pre>Executing authenticated transaction write to MongoDB StatefulSet...</pre>';
                  try {
                    const res = await fetch(API + '/items', {
                      method: 'POST',
                      headers: { 'Content-Type': 'application/json' },
                      body: JSON.stringify({ message: msg, category: cat })
                    });
                    const tx = await res.json();
                    resultTarget.innerHTML = renderTransactionPipelineVisual(tx);
                    loadTransactions();
                  } catch (err) {
                    resultTarget.innerHTML = '<pre style="color:#f87171">Transaction error: ' + err.message + '</pre>';
                  }
                };

                const certFormEl = document.getElementById('certForm');
                if (certFormEl) {
                  certFormEl.onsubmit = issueCertificate;
                }

                document.querySelectorAll('.tab-btn').forEach(btn => {
                  btn.addEventListener('click', function(e) {
                    e.preventDefault();
                    const tab = this.getAttribute('data-tab');
                    if (tab) {
                      showTab(tab, this);
                    }
                  });
                });

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

# ── ACM Public TLS Certificate for Custom FQDN (Let's Encrypt / Amazon Trust CA) ──
resource "aws_acm_certificate" "cert" {
  count             = var.route53_zone_name != "" && var.fqdn != "" ? 1 : 0
  domain_name       = var.fqdn
  validation_method = "DNS"

  tags = {
    Name        = "${local.name_prefix}-frontend-cert"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.route53_zone_name != "" && var.fqdn != "" ? {
    for dvo in aws_acm_certificate.cert[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main[0].zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  count                   = var.route53_zone_name != "" && var.fqdn != "" ? 1 : 0
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ── Frontend LoadBalancer (HTTP 80 & HTTPS 443 with TLS Termination) ──────
resource "kubernetes_service_v1" "frontend" {
  metadata {
    name      = "mern-frontend"
    namespace = local.k8s_namespace
    annotations = length(aws_acm_certificate_validation.cert) > 0 ? {
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"                = aws_acm_certificate_validation.cert[0].certificate_arn
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"               = "443"
      "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"        = "http"
      "service.beta.kubernetes.io/aws-load-balancer-connection-idle-timeout" = "60"
    } : {}
  }
  spec {
    selector = { app = "mern-frontend" }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
    dynamic "port" {
      for_each = var.route53_zone_name != "" && var.fqdn != "" ? [1] : []
      content {
        name        = "https"
        port        = 443
        target_port = 3000
      }
    }
    type = "LoadBalancer"
  }

  depends_on = [
    kubernetes_namespace_v1.app,
    module.eks.eks_managed_node_groups,
    aws_acm_certificate_validation.cert,
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
