# 03 — Hello Vault (Node.js + EC2)

**Polyglot Vault integration: an Express / Node.js application on EC2 authenticating via AWS IAM auth and reading a KV v2 secret using the `node-vault` client.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Node.js](https://img.shields.io/badge/Node.js-20-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20RHEL%209-1F6FEB)

## At a Glance

| | |
|---|---|
| **Language & Runtime** | Node.js 20 + Express · RHEL 9 (EC2) |
| **Infrastructure** | EC2, VPC, IAM Role, Security Group |
| **Vault Auth Method** | AWS IAM (`node-vault` aws login) |
| **Vault Secret Engine** | KV v2 (`apps/hello-vault-node/config`) |
| **HCP Terraform Workspace** | `demo-app-03` |

## Architecture & Authentication Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ AWS EC2 (RHEL 9)                                                                 │
│                                                                                  │
│  Node.js / Express (127.0.0.1:8080)                                              │
│    │                                                                             │
│    │ 1. Signs AWS STS request                                                    │
│    │    using `@aws-sdk/credential-providers`                                    │
│    ▼                                                                             │
│  Vault AWS Auth Login ───────────────▶ HashiCorp Vault                           │
│                                           │                                      │
│                                           │ 2. Validates STS signature & role ARN│
│                                           │ 3. Issues short-lived Vault token    │
│                                           ▼                                      │
│  Reads KV v2 Secret   ◀─────────────── Vault KV v2 Engine                        │
│  (apps/hello-vault-node/config)                                                  │
│    │                                                                             │
│    ▼                                                                             │
│  Serves JSON response                                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. The Node.js service generates signed AWS STS headers using EC2 metadata credentials.
2. The `node-vault` client sends these signed headers to Vault's `auth/aws/login` endpoint.
3. Vault validates the caller identity with AWS and checks the bound IAM role.
4. Vault returns an ephemeral token scoped to `hello-vault-node-read`.
5. The application reads `apps/hello-vault-node/config` from KV v2 and serves JSON responses on port 8080.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-03` workspace:

```hcl
project_name           = "demo"
ami_owner_account_id   = "602343948585"
existing_key_pair_name = "your-ssh-keypair"
allowed_cidr_blocks    = ["x.x.x.x/32"]
vault_address          = "https://vault.christian-renaud.sbx.hashidemos.io"
vault_namespace        = "admin"
```

### 2. Trigger a Run

Push to `main` or trigger a plan/apply in HCP Terraform.

### 3. Verify Application

```bash
# Query the application via public IP
curl http://<public_ip>:8080/
curl http://<public_ip>:8080/health
```

## Prerequisites

- Terraform `>= 1.9.0`
- AWS Account with permissions to provision EC2, VPC, and IAM roles
- Vault server with AWS auth method enabled and configured
- `demo-apps-vault-config` workspace applied to establish the workspace JWT and IAM policies

## Features & Key Capabilities

- **Modern Node.js 20**: Uses native ES modules and Node.js LTS runtime.
- **Zero Stored Credentials**: No static Vault tokens or AWS secret keys stored on disk or in environment variables.
- **IAM Instance Profile Authentication**: Dynamic authentication using EC2 metadata and AWS STS.
- **IMDSv2 Enforced**: EC2 metadata service configured with `http_tokens = "required"`.
- **Encrypted Storage**: EBS root volume encrypted with KMS.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Naming prefix for all AWS resources | `string` | — | yes |
| `ami_owner_account_id` | AWS account ID that owns the approved base AMI | `string` | — | yes |
| `existing_key_pair_name` | Existing EC2 key pair name for SSH access | `string` | — | yes |
| `allowed_cidr_blocks` | CIDRs allowed to SSH and access the instance | `list(string)` | — | yes |
| `vault_address` | Vault cluster URL (e.g. `https://vault.example.com`) | `string` | — | yes |
| `vault_namespace` | Vault namespace (use `"admin"` for HCP Vault) | `string` | `"admin"` | no |
| `aws_region` | AWS region for all resources | `string` | `"us-east-1"` | no |
| `environment` | Deployment environment (`dev`, `staging`, `prod`, `sandbox`) | `string` | `"dev"` | no |
| `instance_type` | EC2 instance type | `string` | `"t3.micro"` | no |
| `vpc_cidr` | VPC CIDR block | `string` | `"10.10.0.0/16"` | no |

## Outputs

| Name | Description |
|---|---|
| `instance_id` | EC2 instance ID |
| `public_ip` | Public IP of the EC2 instance |
| `ssh_command` | Example SSH command to connect to the instance |
| `app_url` | Application HTTP endpoint |
| `vault_role` | Vault AWS auth role name |
| `vault_secret_path` | Full Vault KV path where the secret lives |

## Local Development

```bash
cd app
npm install
cp .env.example .env   # fill in local test values
export $(cat .env | xargs)
npm start
```

> [!IMPORTANT]
> For local development, export a valid `VAULT_TOKEN` — the AWS IAM login flow requires EC2 instance metadata.

## License

Business Source License 1.1
