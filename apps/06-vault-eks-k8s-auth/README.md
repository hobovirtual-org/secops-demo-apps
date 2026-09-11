# 06 — Vault + EKS + Kubernetes Auth

**Cloud-native secret injection: a Node.js application on Amazon EKS receiving secrets via the HashiCorp Vault Agent Injector — zero SDK code and no credentials in the pod spec.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Node.js](https://img.shields.io/badge/Node.js-20-1F6FEB)
![EKS](https://img.shields.io/badge/AWS-EKS%201.32-2EA043)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-Kubernetes-7C5CD8)
![Red Hat](https://img.shields.io/badge/Container-UBI%20Minimal-CC0000)

## At a Glance

| | |
|---|---|
| **Language & Runtime** | Node.js 20 · Amazon EKS 1.32 (AL2023) |
| **Infrastructure** | EKS Managed Node Group, VPC, Vault Agent Injector (Helm) |
| **Vault Auth Method** | Kubernetes (`auth/kubernetes/hello-vault`) |
| **Vault Secret Engine** | KV v2 (`apps/hello-vault/config`) |
| **HCP Terraform Workspace** | `demo-app-06` |

## Architecture & Secret Injection Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ Amazon EKS Cluster (v1.32)                                                       │
│                                                                                  │
│  Kubernetes Pod                                                                  │
│  ┌────────────────────────────────────────────────────────┐                      │
│  │ initContainer: vault-agent-init                        │                      │
│  │   1. Reads projected ServiceAccount token              │                      │
│  │   2. Authenticates to Vault (auth/kubernetes)          │                      │
│  │   3. Fetches KV v2 secret & renders to emptyDir volume │                      │
│  └────────────────────────────────────────────────────────┘                      │
│                           │                                                      │
│                           ▼                                                      │
│  ┌────────────────────────────────────────────────────────┐                      │
│  │ shared volume (/vault/secrets/config.json)             │                      │
│  └────────────────────────────────────────────────────────┘                      │
│                           ▲                                                      │
│                           │                                                      │
│  ┌────────────────────────────────────────────────────────┐                      │
│  │ app container: hello-vault-node                        │                      │
│  │   4. Reads /vault/secrets/config.json directly from disk│                     │
│  │   5. Serves application on port 8080                   │                      │
│  └────────────────────────────────────────────────────────┘                      │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. The Vault Agent Injector intercepts Pod creation via a Kubernetes `MutatingWebhookConfiguration`.
2. It injects an init container (`vault-agent-init`) and a sidecar container (`vault-agent`).
3. The init container uses the pod's projected ServiceAccount JWT to authenticate with Vault.
4. Vault validates the JWT with the EKS OIDC discovery endpoint and returns an ephemeral token.
5. Vault Agent renders the secret template to `/vault/secrets/config.json` on a shared `emptyDir` volume.
6. The Node.js application reads the JSON configuration directly from the filesystem at startup.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-06` workspace:

```hcl
project_name    = "demo"
vault_address   = "https://vault.christian-renaud.sbx.hashidemos.io"
vault_namespace = ""
```

### 2. Trigger a Run

Push to `main` or trigger a plan/apply in HCP Terraform.

### 3. Connect and Verify Cluster

```bash
# Update local kubeconfig
aws eks update-kubeconfig --region us-east-1 --name demo-hello-vault-cluster

# Check running pods in the application namespace
kubectl get pods -n hello-vault

# Verify injected secret inside the application container
kubectl exec -n hello-vault deploy/hello-vault-node -c hello-vault-node -- cat /vault/secrets/config.json

# Test application endpoint
kubectl port-forward -n hello-vault svc/hello-vault-node 8080:80
curl http://localhost:8080/
```

## Prerequisites

- Terraform `>= 1.9.0`
- AWS Account with permissions to provision EKS, VPC, subnets, and IAM roles
- Vault server accessible from the EKS VPC
- `demo-apps-vault-config` workspace applied

## Features & Key Capabilities

- **Zero Secret SDK Code**: The application has no Vault SDK dependencies and reads standard configuration files.
- **Mutating Webhook Injection**: Vault Agent is declaratively injected via Kubernetes Pod annotations.
- **Automated Token Rotation**: The sidecar agent manages token renewal and lease lifecycles automatically.
- **AL2023 Managed Nodes**: Amazon Linux 2023 nodes configured with IMDSv2 hop limits for AWS CNI DaemonSet.
- **Compliant Base Images**: Runs on Red Hat Universal Base Image (UBI 9 Minimal).

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Naming prefix for resources | `string` | — | yes |
| `vault_address` | Vault cluster URL | `string` | — | yes |
| `vault_namespace` | Vault namespace (`""` for root / self-managed, `"admin"` for HCP) | `string` | `""` | no |
| `aws_region` | AWS region | `string` | `"us-east-1"` | no |
| `environment` | Deployment environment (`dev`, `staging`, `prod`, `sandbox`) | `string` | `"dev"` | no |
| `vpc_cidr` | VPC CIDR block | `string` | `"10.20.0.0/16"` | no |
| `node_instance_type` | EKS managed node group instance type | `string` | `"t3.small"` | no |
| `desired_node_count` | Desired number of EKS nodes | `number` | `2` | no |

## Outputs

| Name | Description |
|---|---|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | EKS API server endpoint |
| `vault_k8s_auth_path` | Vault Kubernetes auth mount path |
| `vault_secret_path` | Full Vault KV secret path |
| `kubeconfig_command` | AWS CLI command to update local kubeconfig |

## License

Business Source License 1.1
