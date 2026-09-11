# 02 — Hello Vault (Go + EC2)

**Polyglot Vault integration: a Go application on EC2 authenticating via AWS IAM auth and reading a KV v2 secret using the official Vault Go SDK.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Go](https://img.shields.io/badge/Go-1.23-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20RHEL%209-1F6FEB)

## At a Glance

| | |
|---|---|
| **Language & Runtime** | Go 1.23 · RHEL 9 (EC2) |
| **Infrastructure** | EC2, VPC, IAM Role, Security Group, Route 53 |
| **Vault Auth Method** | AWS IAM (`vault/api/auth/aws`) |
| **Vault Secret Engine** | KV v2 (`apps/hello-vault-go/config`) |
| **HCP Terraform Workspace** | `demo-app-02` |

## Architecture & Authentication Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ AWS EC2 (RHEL 9)                                                                 │
│                                                                                  │
│  Go Web Service (127.0.0.1:8080)                                                 │
│    │                                                                             │
│    │ 1. Signs AWS STS request                                                    │
│    │    using official Vault Go SDK (`auth/aws`)                                 │
│    ▼                                                                             │
│  Vault AWS Auth Login ───────────────▶ HashiCorp Vault                           │
│                                           │                                      │
│                                           │ 2. Validates STS signature & role ARN│
│                                           │ 3. Issues short-lived Vault token    │
│                                           ▼                                      │
│  Reads KV v2 Secret   ◀─────────────── Vault KV v2 Engine                        │
│  (apps/hello-vault-go/config)                                                    │
│    │                                                                             │
│    ▼                                                                             │
│  Serves JSON response                                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. The compiled Go binary uses `github.com/hashicorp/vault/api/auth/aws` to generate a signed `sts:GetCallerIdentity` request using EC2 instance credentials.
2. The Go SDK calls Vault's AWS auth endpoint (`auth/aws/login`).
3. Vault verifies the STS request against the bound IAM role ARN.
4. Vault issues a short-lived token scoped to the `hello-vault-go-read` policy.
5. The application calls `client.KVv2(mount).Get(ctx, path)` to fetch configuration and serves responses on port 8080.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-02` workspace:

```hcl
project_name           = "demo"
ami_owner_account_id   = "602343948585"
existing_key_pair_name = "your-ssh-keypair"
allowed_cidr_blocks    = ["x.x.x.x/32"]
vault_address          = "https://vault.christian-renaud.sbx.hashidemos.io"
vault_namespace        = ""
route53_zone_name      = "christian-renaud.sbx.hashidemos.io"
fqdn                   = "hello-go.christian-renaud.sbx.hashidemos.io"
```

### 2. Trigger a Run

Push to `main` or trigger a plan/apply in HCP Terraform.

### 3. Verify Application

```bash
# Query the application via public DNS or IP
curl http://hello-go.christian-renaud.sbx.hashidemos.io:8080/
curl http://hello-go.christian-renaud.sbx.hashidemos.io:8080/health
```

## Prerequisites

- Terraform `>= 1.9.0`
- AWS Account with permissions to provision EC2, VPC, Route 53, and IAM roles
- Vault server with AWS auth method enabled and configured
- `demo-apps-vault-config` workspace applied to establish the workspace JWT and IAM policies

## Features & Key Capabilities

- **Official Vault SDK**: Implements native `github.com/hashicorp/vault/api` with structured error handling.
- **Zero Stored Credentials**: No static Vault tokens or AWS secret keys stored on disk or in environment variables.
- **IAM Instance Profile Authentication**: Dynamic authentication using EC2 metadata and AWS STS.
- **IMDSv2 Enforced**: EC2 metadata service configured with `http_tokens = "required"`.
- **Encrypted Storage**: EBS root volume encrypted with KMS.
- **Automated DNS**: Public Route 53 A record created automatically.

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `project_name` | Naming prefix for all AWS resources | `string` | — | yes |
| `ami_owner_account_id` | AWS account ID that owns the approved base AMI | `string` | — | yes |
| `existing_key_pair_name` | Existing EC2 key pair name for SSH access | `string` | — | yes |
| `allowed_cidr_blocks` | CIDRs allowed to SSH and access the instance | `list(string)` | — | yes |
| `vault_address` | Vault cluster URL (e.g. `https://vault.example.com`) | `string` | — | yes |
| `route53_zone_name` | Public Route53 hosted zone name | `string` | — | yes |
| `fqdn` | Fully qualified domain name for the app | `string` | — | yes |
| `vault_namespace` | Vault namespace (`""` for root / self-managed, `"admin"` for HCP) | `string` | `""` | no |
| `aws_region` | AWS region for all resources | `string` | `"us-east-1"` | no |
| `environment` | Deployment environment (`dev`, `staging`, `prod`, `sandbox`) | `string` | `"dev"` | no |
| `instance_type` | EC2 instance type | `string` | `"t3.small"` | no |
| `vpc_cidr` | VPC CIDR block | `string` | `"10.10.0.0/16"` | no |

## Outputs

| Name | Description |
|---|---|
| `instance_id` | EC2 instance ID |
| `public_ip` | Public IP of the EC2 instance |
| `ssh_command` | Example SSH command to connect to the instance |
| `app_url` | Application HTTP endpoint (DNS-based) |
| `app_url_ip` | Application HTTP endpoint (direct IP fallback) |
| `dns_record` | Route 53 A record FQDN |
| `vault_role` | Vault AWS auth role name |
| `vault_secret_path` | Full Vault KV path where the secret lives |

## Local Development

```bash
cd app
cp .env.example .env   # fill in local test values
export $(cat .env | xargs)
go run main.go
```

> [!IMPORTANT]
> For local development, export a valid `VAULT_TOKEN` — the AWS IAM login flow requires EC2 instance metadata.

## License

Business Source License 1.1
