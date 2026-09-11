# 07 — MERN + Vault

**Production-grade full MERN stack on Amazon EKS with MongoDB credentials dynamically injected by HashiCorp Vault Agent and EDR monitoring via Uptycs.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![React](https://img.shields.io/badge/React-19-1F6FEB)
![Node.js](https://img.shields.io/badge/Node.js-20-2EA043)
![MongoDB](https://img.shields.io/badge/MongoDB-7.0-2EA043)
![EKS](https://img.shields.io/badge/AWS-EKS%201.32-7C5CD8)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-Kubernetes-7C5CD8)
![Red Hat](https://img.shields.io/badge/Container-UBI%20Minimal-CC0000)

## At a Glance

| | |
|---|---|
| **Stack & Components** | React 19 Frontend + Express Backend + MongoDB 7 StatefulSet |
| **Infrastructure** | Amazon EKS 1.32 (AL2023), VPC, Vault Agent Injector, Uptycs EDR Sensor |
| **Vault Auth Method** | Kubernetes (`auth/kubernetes/mern-vault`) |
| **Vault Secret Engine** | KV v2 (`apps/mern-vault/mongodb`) |
| **HCP Terraform Workspace** | `demo-app-07` |

## Architecture & Secret Injection Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ Amazon EKS Cluster (v1.32)                                                       │
│                                                                                  │
│  User Browser                                                                    │
│    │                                                                             │
│    ▼ (Port 80)                                                                   │
│  mern-frontend (React 19 / UBI 9 Minimal)                                        │
│    │                                                                             │
│    ▼ (Port 3001)                                                                 │
│  mern-backend (Express / Node 20 / UBI 9 Minimal)                                │
│    ├── Pod Init: vault-agent-init (Auths to Vault via K8s SA JWT)                │
│    ├── Injected Volume: /vault/secrets/config.json (DB credentials & JWT secret) │
│    │                                                                             │
│    ▼ (Port 27017)                                                                │
│  mongodb (StatefulSet / RHEL 9 MongoDB 7.0)                                      │
│    ├── Injected Volume: /vault/secrets/mongodb.env (Admin credentials)           │
│    └── PersistentVolumeClaim: 5Gi GP3                                            │
│                                                                                  │
│  DaemonSet: Uptycs EDR Sensor (Security & Compliance monitoring)                 │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. **Vault Secret Provisioning**: Terraform generates a secure random password and writes the credentials to Vault KV v2 at `apps/mern-vault/mongodb`.
2. **Kubernetes Auth**: The backend and MongoDB pods authenticate to Vault using their ServiceAccount projected tokens.
3. **Vault Agent Injector**: Intercepts pod deployment and injects Vault Agent sidecars/init-containers.
4. **Secret Delivery**: Renders `/vault/secrets/config.json` for the backend and `/vault/secrets/mongodb.env` for MongoDB root init.
5. **Runtime Decoupling**: No static database credentials exist in Kubernetes Secret objects, container environment variables, or Git repositories.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-07` workspace:

```hcl
project_name        = "demo"
vault_address       = "https://vault.christian-renaud.sbx.hashidemos.io"
vault_namespace     = ""
node_instance_type  = "t3.medium"
desired_node_count  = 2
developer_role_arns = ["arn:aws:iam::602343948585:role/aws_christian.renaud_test-developer"]
```

### 2. Trigger a Run

Push to `main` or trigger a plan/apply in HCP Terraform.

### 3. Access and Verify the Cluster

```bash
# Configure local kubectl context
aws eks update-kubeconfig --region us-east-1 --name demo-mern-vault-cluster

# View cluster workloads
kubectl get pods -n mern-vault

# Verify injected database config in the backend pod
kubectl exec -n mern-vault deploy/mern-backend -c mern-backend -- cat /vault/secrets/config.json

# Retrieve the React frontend public LoadBalancer URL
kubectl get svc mern-frontend -n mern-vault
```

## Prerequisites

- Terraform `>= 1.9.0`
- AWS Account with permissions to provision EKS, VPC, subnets, and IAM roles
- Vault server accessible from the EKS VPC
- `demo-apps-vault-config` workspace applied

## Features & Key Capabilities

- **Zero Hardcoded Secrets**: MongoDB credentials and application JWT secrets are managed entirely inside Vault.
- **Microservices Pod Injection**: Multiple services (Express backend & MongoDB init) consume secrets via Vault Agent templates.
- **Enterprise Security Compliance**: Uptycs EDR sensor deployed on all worker nodes.
- **Red Hat UBI Minimal Images**: All custom application images are based on `registry.redhat.io/ubi9/nodejs-20-minimal` and `registry.redhat.io/rhel9/mongodb-70`.
- **EKS Access Entries**: Developer IAM roles mapped directly with `AmazonEKSClusterAdminPolicy`.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Naming prefix for cluster and resources | `string` | — | yes |
| `vault_address` | Vault cluster URL | `string` | — | yes |
| `uptycs_helm_repo_url` | Helm repository URL for IBM CISO Uptycs chart | `string` | — | yes |
| `uptycs_chart_version` | Uptycs Helm chart version | `string` | — | yes |
| `uptycs_owner_email` | OWNER tag email for Uptycs compliance | `string` | — | yes |
| `vault_namespace` | Vault namespace (`""` for root / self-managed, `"admin"` for HCP) | `string` | `""` | no |
| `aws_region` | AWS region | `string` | `"us-east-1"` | no |
| `environment` | Deployment environment (`dev`, `staging`, `prod`, `sandbox`) | `string` | `"dev"` | no |
| `vpc_cidr` | VPC CIDR block | `string` | `"10.30.0.0/16"` | no |
| `node_instance_type` | EKS node instance type | `string` | `"t3.medium"` | no |
| `desired_node_count` | Desired EKS node count | `number` | `2` | no |
| `developer_role_arns` | IAM role ARNs granted EKS admin access | `list(string)` | `[]` | no |
| `uptycs_update_tag` | Uptycs UPDATE tag per IBM Tag Guide | `string` | `"NONE"` | no |
| `mongodb_atlas_public_key` | MongoDB Atlas API key (for optional Atlas integration) | `string` | `""` | no (sensitive) |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | EKS cluster API server endpoint |
| `cluster_certificate_authority_data` | Base64-encoded CA data for the EKS cluster |
| `vault_secret_path` | Vault KV path for MongoDB credentials |
| `kubeconfig_command` | Command to configure kubectl for the cluster |
| `kubectl_context` | Full kubectl context name |
| `frontend_service` | Command to inspect the React frontend service |
| `uptycs_tag_string` | IBM tag string applied to the Uptycs sensor |
| `uptycs_node_uuid_command` | Command to retrieve node UUIDs for Uptycs verification |

## Local Development

```bash
# Backend
cd app/backend
cp .env.example .env
echo '{"mongo_username":"root","mongo_password":"test","mongo_host":"localhost","mongo_port":"27017","mongo_database":"merndb","jwt_secret":"test"}' > secrets.json
npm install && npm start

# Frontend (in a separate terminal)
cd app/frontend
cp .env.example .env
npm install && npm run dev
```

> [!IMPORTANT]
> For local development without Kubernetes, run MongoDB locally: `docker run -d -p 27017:27017 -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=test mongo:7`

## License

Business Source License 1.1
