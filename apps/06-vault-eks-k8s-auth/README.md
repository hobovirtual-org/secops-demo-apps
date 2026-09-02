# 06 — Vault + EKS + Kubernetes Auth

**Node.js app on EKS that receives Vault secrets via the Vault Agent Injector — no SDK code, no tokens in the app.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Node.js](https://img.shields.io/badge/Node.js-20-1F6FEB)
![EKS](https://img.shields.io/badge/AWS-EKS%201.32-2EA043)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-Kubernetes-7C5CD8)

## At a Glance

| | |
|---|---|
| **Language** | Node.js 20 |
| **Infrastructure** | EKS 1.32 (managed node group), VPC |
| **Vault auth method** | Kubernetes (JWT ServiceAccount token) |
| **Vault secret** | KV v2 — injected by Vault Agent |
| **HCP Terraform workspace** | `demo-app-06-vault-eks-k8s-auth` |

## How it works

```
Pod (ServiceAccount JWT) ──k8s_login──▶ Vault Kubernetes auth
                                               │
                                      short-lived Vault token
                                               │
                                  Vault Agent (sidecar) reads secret
                                               │
                              writes to /vault/secrets/config.json
                                               │
                              App reads the file — zero Vault SDK code
```

The Vault Agent Injector (deployed via Helm) intercepts Pod creation, injects a `vault-agent-init` init container and a `vault-agent` sidecar, authenticates using the pod's ServiceAccount JWT, and writes the secret to a shared `emptyDir` volume at `/vault/secrets/`.

## Quick Start

### 1. Set workspace variables

```
project_name    = "demo"
vault_address   = "https://vault.example.com"
vault_namespace = "admin"
```

### 2. Trigger a run

```bash
aws eks update-kubeconfig --region us-east-1 --name <cluster_name>
kubectl get pods -n hello-vault
kubectl exec -n hello-vault deploy/hello-vault-node -- cat /vault/secrets/config.json
```

### 3. Test

```bash
kubectl port-forward -n hello-vault svc/hello-vault-node 8080:80
curl http://localhost:8080/
```

## Infrastructure highlights

- EKS 1.32 managed node group (RHEL nodes via custom AMI or Amazon Linux 2023)
- Vault Agent Injector installed via the official HashiCorp Helm chart
- Kubernetes auth method configured to trust the cluster's OIDC issuer
- ServiceAccount bound to a Vault role — no tokens in manifests
