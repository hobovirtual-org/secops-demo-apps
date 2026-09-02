# secops-demo-apps

**A polyglot mono-repo of demo applications that consume secrets from HashiCorp Vault — running on EC2 and EKS, managed by HCP Terraform.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![HCP Terraform](https://img.shields.io/badge/HCP%20Terraform-enabled-2EA043)
![Vault](https://img.shields.io/badge/HashiCorp%20Vault-JWT%20%7C%20AWS%20%7C%20K8s%20Auth-1F6FEB)

## At a Glance

| | |
|---|---|
| **HCP Terraform org** | `crenaud-org` |
| **Vault server** | [`secops-vault-dev`](https://github.com/hobovirtual-org/secops-vault-dev) — self-managed, root namespace |
| **AWS account** | `602343948585` · region `us-east-1` |
| **AWS Provider** | `hashicorp/aws = 6.62.0` |
| **Vault Provider** | `hashicorp/vault = 5.11.0` |
| **Terraform** | `>= 1.9.0` |
| **No secrets in code** | Zero static tokens anywhere — all workspaces use JWT dynamic credentials |

## Repository layout

```
secops-demo-apps/
│
├── vault-config/                         ← Vault JWT roles + policies for all app workspaces
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
    └── eks-vault-stack/                 ← HCP Terraform Stack (apps 06 + 07)
```

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

## Authentication model — zero stored tokens

Every HCP Terraform workspace in this repo authenticates to Vault using **JWT dynamic credentials** (`TFC_VAULT_PROVIDER_AUTH`). No `VAULT_TOKEN` is stored anywhere.

```
HCP Terraform run
  └── signed JWT (issued per run, scoped to workspace name)
        └── Vault JWT auth backend (path: jwt)
              └── short-lived token (15 min, scoped policy)
                    └── Terraform Vault provider
```

### Workspace run order

```
demo-apps-vault-config          ← provisions JWT roles + policies for all app workspaces
  └── demo-app-01               ← Vault KV secret + AWS auth role + EC2 instance
  └── demo-app-02 … demo-app-07
```

`demo-apps-vault-config` **must converge before** any app workspace runs. Workspace dependencies are configured in [`platform-control-workspace`](https://github.com/hobovirtual-org/platform-control-workspace).

### One-time Vault bootstrap (already done)

The JWT auth backend and the `demo-apps-vault-config` role were created once via CLI. This is documented in [`PREREQUISITES.md`](PREREQUISITES.md) for reference.

## How secrets reach the app at runtime

### EC2 apps (01–05) — Vault AWS IAM auth

```
EC2 instance (IAM role attached)
  └── sts:GetCallerIdentity (signed request)
        └── Vault AWS auth backend
              └── short-lived Vault token
                    └── read KV v2 secret → app uses secret
```

The EC2 instance's IAM role is bound to a Vault AWS auth role. No tokens are stored on disk. Vault verifies the instance identity via AWS STS.

### EKS apps (06–07) — Vault Kubernetes auth + Agent Injector

```
Pod (ServiceAccount JWT)
  └── Vault Kubernetes auth backend
        └── Vault Agent (init + sidecar containers)
              └── rendered secret → /vault/secrets/ (emptyDir)
                    └── app reads the file (no Vault SDK needed)
```

The Vault Agent Injector intercepts pod creation via a `MutatingWebhookConfiguration`, authenticates using the pod's ServiceAccount JWT, and renders secret templates into a shared volume.

## Shared modules

| Module | What it creates |
|---|---|
| [`_shared/vault-aws-auth`](_shared/vault-aws-auth/) | AWS auth backend mount + role bound to EC2 IAM role |
| [`_shared/vault-kv-secret`](_shared/vault-kv-secret/) | KV v2 mount + initial secret + read-only policy |

## HCP Terraform workspaces

All workspaces are provisioned as code by [`platform-control-workspace`](https://github.com/hobovirtual-org/platform-control-workspace). Never create them manually in the UI.

| Workspace | Working directory | Purpose |
|---|---|---|
| `demo-apps-vault-config` | `vault-config/` | JWT roles + policies for all app workspaces |
| `demo-app-01` | `apps/01-hello-vault-python-ec2/terraform` | Python EC2 app |
| `demo-app-02` | `apps/02-hello-vault-go-ec2/terraform` | Go EC2 app |
| `demo-app-03` | `apps/03-hello-vault-node-ec2/terraform` | Node.js EC2 app |
| `demo-app-04` | `apps/04-hello-vault-java-ec2/terraform` | Java EC2 app |
| `demo-app-05` | `apps/05-vault-dynamic-aws-creds/terraform` | Dynamic AWS creds |
| `demo-app-06` | `apps/06-vault-eks-k8s-auth/terraform` | EKS + K8s auth |
| `demo-app-07` | `apps/07-mern-vault/terraform` | MERN stack on EKS |

Apps 06–07 are also deployable as an HCP Terraform Stack via [`stacks/eks-vault-stack/`](stacks/eks-vault-stack/).

## Prerequisites

> [!IMPORTANT]
> Full setup instructions are in [`PREREQUISITES.md`](PREREQUISITES.md). Read it before triggering any run.

Key requirements:

- Vault server running and unsealed at `https://vault.christian-renaud.sbx.hashidemos.io`
- JWT auth bootstrap completed (one-time CLI steps — see PREREQUISITES.md)
- `platform-control-workspace` applied — creates all HCP Terraform workspaces
- `demo-apps-vault-config` applied — creates Vault JWT roles for app workspaces

## Security posture

| Control | Implementation |
|---|---|
| No static Vault tokens | All workspaces use JWT dynamic credentials (`TFC_VAULT_PROVIDER_AUTH`) |
| No secrets in Terraform state | Vault tokens are ephemeral; passwords marked `sensitive` |
| No secrets in code | Zero hardcoded credentials anywhere in this repo |
| Container images | `registry.redhat.io` (UBI minimal) — never Docker Hub |
| Non-root containers | `USER 1001` in all Dockerfiles |
| No `0.0.0.0` binding | EC2 apps bind to `127.0.0.1` only |
| IMDSv2 enforced | All EC2 instances use `http_tokens = "required"` |
| EBS encryption | All root volumes encrypted |
| Dynamic AWS creds | App 05 demonstrates Vault-issued short-lived IAM keys |

## Adding a new app

1. Copy `apps/01-hello-vault-python-ec2/` as a template — rename the directory and workspace name in `terraform.tf`.
2. Add an entry to [`vault-config/main.tf`](vault-config/main.tf) — one `vault_policy` + one `vault_jwt_auth_backend_role` block.
3. Add a workspace file to `platform-control-workspace` following the pattern in `demo-app-01-workspace.tf`.
4. Add the app to the CI matrix in [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml).
5. Trigger `platform-control-workspace` → `demo-apps-vault-config` → new app workspace in order.

## License

Business Source License 1.1 — see `LICENSE` if present, otherwise all rights reserved.
