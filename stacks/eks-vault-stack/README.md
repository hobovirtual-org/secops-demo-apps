# EKS Vault Stack

**HCP Terraform Stack that orchestrates VPC + EKS + Vault Kubernetes auth + app workload as a single deployable unit.**

![Terraform Stacks](https://img.shields.io/badge/HCP%20Terraform-Stacks-7A3FF2)
![EKS](https://img.shields.io/badge/AWS-EKS%201.32-2EA043)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-Kubernetes-7C5CD8)

## At a Glance

| | |
|---|---|
| **Type** | HCP Terraform Stack |
| **Components** | VPC → EKS → vault-secret → vault-k8s-auth → app-workload |
| **Auth** | OIDC dynamic credentials (no long-lived keys) |
| **Deployments** | `dev` (ready), `prod` (commented, add when needed) |

## Component dependency graph

```
identity_token (OIDC)
       │
provider.aws.main
       │
  ┌────▼────┐
  │   vpc   │
  └────┬────┘
       │
  ┌────▼────┐
  │   eks   │──────────────────────────┐
  └────┬────┘                         │
       │                         provider.kubernetes.main
  ┌────▼──────────┐               provider.helm.main
  │ vault_secret  │                    │
  └────┬──────────┘             ┌──────▼─────────┐
       │                        │     app        │
  ┌────▼───────────┐            └────────────────┘
  │ vault_k8s_auth │
  └────────────────┘
```

## Deploy

```bash
# Install Terraform >= 1.14.5 (Stacks CLI)
terraform stacks init
terraform stacks validate
terraform stacks configuration upload
```

> [!IMPORTANT]
> Update `aws_role_arn` in `deployments.tfdeploy.hcl` to match your IAM role for OIDC.

## What gets created per deployment

| Resource | Details |
|---|---|
| VPC | 10.40.0.0/16, 2 AZs, NAT gateway |
| EKS cluster | 1.32, managed node group |
| Vault KV v2 | `apps/eks-vault-stack/data/config` |
| Vault K8s auth | `kubernetes/eks-vault-stack` |
| Vault Agent Injector | Helm chart `vault 0.30.0` |
| App deployment | Node.js reading secrets from `/vault/secrets/config.json` |
