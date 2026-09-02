# secops-demo-apps

**A polyglot mono-repo of demo applications that consume secrets from HashiCorp Vault — running on EC2 and EKS, managed by HCP Terraform.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![HCP Terraform](https://img.shields.io/badge/HCP%20Terraform-enabled-2EA043)
![Vault](https://img.shields.io/badge/HashiCorp%20Vault-AWS%20%7C%20K8s%20Auth-1F6FEB)

## At a Glance

| | |
|---|---|
| **HCP Terraform org** | `crenaud-org` |
| **Vault server** | [`secops-vault-dev`](https://github.com/hobovirtual-org/secops-vault-dev) |
| **AWS Provider** | `hashicorp/aws = 6.62.0` |
| **Vault Provider** | `hashicorp/vault = 5.11.0` |
| **Terraform** | `>= 1.9.0` |
| **Authentication** | EC2: AWS IAM auth · EKS: Kubernetes auth (Vault Agent Injector) |
| **No secrets in code** | Secrets delivered at runtime via Vault — zero static tokens or passwords |

## Repository layout

```
secops-demo-apps/
│
├── _shared/                              ← Reusable Terraform modules
│   ├── vault-aws-auth/                   ← AWS auth method + role
│   └── vault-kv-secret/                 ← KV v2 engine + read-only policy
│
├── apps/
│   ├── 01-hello-vault-python-ec2/       ← Python + Flask on EC2
│   ├── 02-hello-vault-go-ec2/           ← Go on EC2
│   ├── 03-hello-vault-node-ec2/         ← Node.js on EC2
│   ├── 04-hello-vault-java-ec2/         ← Java Spring Boot on EC2
│   ├── 05-vault-dynamic-aws-creds/      ← Python + Vault AWS secrets engine
│   ├── 06-vault-eks-k8s-auth/           ← Node.js on EKS + Vault Agent
│   └── 07-mern-vault/                   ← MERN stack on EKS
│
└── stacks/
    └── eks-vault-stack/                 ← HCP Terraform Stack (multi-component)
```

Apps 01–05 each have an independent Terraform root with their own HCP Terraform workspace. Apps 06–07 are deployed together via the [`stacks/eks-vault-stack/`](stacks/eks-vault-stack/) HCP Terraform Stack. Each `apps/*/app/` directory contains the application source code and Dockerfile.

## Apps at a glance

| # | App | Language | Runtime | Vault Auth | Vault Secret |
|---|---|---|---|---|---|
| 01 | Hello Vault | Python 3.11 + Flask | EC2 (RHEL 9) | AWS IAM | KV v2 |
| 02 | Hello Vault | Go 1.23 | EC2 (RHEL 9) | AWS IAM | KV v2 |
| 03 | Hello Vault | Node.js 20 + Express | EC2 (RHEL 9) | AWS IAM | KV v2 |
| 04 | Hello Vault | Java 21 + Spring Boot | EC2 (RHEL 9) | AWS IAM | KV v2 |
| 05 | Dynamic AWS Creds | Python 3.11 + Flask | EC2 (RHEL 9) | AWS IAM | AWS secrets engine |
| 06 | EKS + K8s Auth | Node.js 20 | EKS 1.32 | Kubernetes | KV v2 (Agent Injector) |
| 07 | MERN Stack | React 19 + Express + MongoDB | EKS 1.32 | Kubernetes | KV v2 (Agent Injector) |

## How secrets work

### EC2 apps (01–05) — AWS IAM auth

```
EC2 (IAM role attached) ──sts:GetCallerIdentity──▶ Vault AWS auth
                                                          │
                                                  short-lived token
                                                          │
                                                  read KV v2 secret
                                                          │
                                                    app uses secret
```

The EC2 instance's IAM role is bound to a Vault role. No tokens are stored on disk.

### EKS apps (06–07) — Kubernetes auth + Vault Agent Injector

```
Pod (ServiceAccount JWT) ──k8s_login──▶ Vault Kubernetes auth
                                               │
                                       short-lived token
                                               │
                                   Vault Agent (sidecar/init)
                                               │
                              /vault/secrets/<name>.json  (emptyDir)
                                               │
                                     App reads the file
                                     (zero Vault SDK code needed)
```

The Vault Agent Injector intercepts pod creation via a MutatingWebhookConfiguration, injects an init container and sidecar, authenticates, and renders templates to a shared `emptyDir` volume.

## Shared modules

| Module | What it creates |
|---|---|
| [`_shared/vault-aws-auth`](_shared/vault-aws-auth/) | AWS auth backend mount + role |
| [`_shared/vault-kv-secret`](_shared/vault-kv-secret/) | KV v2 mount + initial secret + read-only policy |

## HCP Terraform strategy

This repo uses **two complementary HCP Terraform deployment models**:

| Model | Used for | Why |
|---|---|---|
| **VCS-driven workspaces** | Apps 01–05 (EC2) | Single-root Terraform, simple infra — a workspace per app is the right fit |
| **Terraform Stacks** | Apps 06–07 (EKS) | Multi-component orchestration (VPC → EKS → Vault K8s auth → workload) benefits from Stack dependency management |

### Workspaces (EC2 apps 01–05)

| Workspace | Working directory |
|---|---|
| `demo-app-01-hello-vault-python` | `apps/01-hello-vault-python-ec2/terraform` |
| `demo-app-02-hello-vault-go` | `apps/02-hello-vault-go-ec2/terraform` |
| `demo-app-03-hello-vault-node` | `apps/03-hello-vault-node-ec2/terraform` |
| `demo-app-04-hello-vault-java` | `apps/04-hello-vault-java-ec2/terraform` |
| `demo-app-05-vault-dynamic-aws` | `apps/05-vault-dynamic-aws-creds/terraform` |

### Stack (EKS apps 06–07)

[`stacks/eks-vault-stack/`](stacks/eks-vault-stack/) is an HCP Terraform Stack that orchestrates:

```
VPC ──▶ EKS ──▶ vault-kv-secret ──▶ vault-k8s-auth ──▶ app-workload
```

All five components are deployed in a single Stack run with automatic dependency ordering.
The `dev` deployment is pre-configured with the correct Vault address.
Before uploading, replace `REPLACE_WITH_YOUR_ACCOUNT_ID` in
[`stacks/eks-vault-stack/deployments.tfdeploy.hcl`](stacks/eks-vault-stack/deployments.tfdeploy.hcl)
with your actual AWS account ID.

## Prerequisites

> [!IMPORTANT]
> Full setup instructions — Vault server → HCP Terraform org → variable sets → OIDC IAM role → apps — are documented in [`PREREQUISITES.md`](PREREQUISITES.md). Read it before triggering any run.

### Tool requirements

| Tool | Minimum version | Purpose |
|---|---|---|
| Terraform CLI | `>= 1.9.0` | EC2 apps |
| Terraform CLI | `>= 1.14.5` | Stacks (use `.terraform-version`) |
| AWS CLI | `>= 2.0` | EKS kubeconfig, OIDC |
| kubectl | `>= 1.29` | EKS workloads |
| Helm | `>= 3.0` | Vault Agent Injector |
| vault CLI | any | Smoke-testing secrets |

### Required infrastructure (from `secops-vault-dev`)

| Dependency | Value |
|---|---|
| **Vault URL** | `https://vault.christian-renaud.sbx.hashidemos.io` |
| **Vault namespace** | `admin` |
| **AMI owner account** | `888995627335` |
| **EC2 key pair name** | `linux` |

## Quick Start (App 01 — simplest)

### 1. Create the HCP Terraform workspace

In `crenaud-org`, create a VCS-driven workspace named `demo-app-01-hello-vault-python` pointed at this repo with a working directory of `apps/01-hello-vault-python-ec2/terraform`.

### 2. Set workspace variables

```
project_name           = "demo"
ami_owner_account_id   = "888995627335"
existing_key_pair_name = "linux"
allowed_cidr_blocks    = ["x.x.x.x/32"]
vault_address          = "https://vault.christian-renaud.sbx.hashidemos.io"
vault_namespace        = "admin"
```

Attach the three variable sets described in [PREREQUISITES.md](PREREQUISITES.md#layer-3--hcp-terraform-crenaud-org) — `vault-demo-connection`, `aws-dynamic-creds-demo`, and `demo-apps-shared`.

### 3. Trigger a run and test

```bash
curl http://<public_ip>:8080/
# {"status":"ok","greeting":"Hello from Vault + Python!","db_username":"appuser"}
```

## Security posture

| Control | Implementation |
|---|---|
| No static Vault tokens | EC2: AWS IAM auth · EKS: K8s JWT auth |
| No secrets in state | Vault token is ephemeral; passwords marked `sensitive` |
| Container images | `registry.redhat.io` (UBI minimal) — never Docker Hub |
| Non-root containers | `USER 1001` in all Dockerfiles |
| No 0.0.0.0 binding | EC2 apps bind to `127.0.0.1` only |
| Dynamic credentials | App 05 demonstrates Vault-issued short-lived IAM keys |
| HCP Terraform OIDC | Stack deployments use OIDC, never long-lived AWS keys |

## Adding a new app

1. Create `apps/NN-my-app/terraform/` — copy `terraform.tf`, `providers.tf`, `variables.tf` from App 01 and rename the workspace.
2. Create `apps/NN-my-app/app/` — add your application source and `Dockerfile`.
3. Add the workspace to the CI matrix in [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml).
4. Add Dependabot entries in [`.github/dependabot.yml`](.github/dependabot.yml).
5. Create the HCP Terraform workspace and set variables.

## License

Business Source License 1.1 — see `LICENSE` if present, otherwise all rights reserved.
