# 04 — Hello Vault (Java Spring Boot + EC2)

**Polyglot Vault integration: a Spring Boot application on EC2 authenticating to Vault via AWS IAM auth and reading a KV v2 secret using the `vault-java-driver`.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Java](https://img.shields.io/badge/Java-21-1F6FEB)
![Spring Boot](https://img.shields.io/badge/Spring%20Boot-3.4.5-2EA043)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20RHEL%209-1F6FEB)

## At a Glance

| | |
|---|---|
| **Language & Runtime** | Java 21 + Spring Boot 3.4.5 · RHEL 9 (EC2) |
| **Infrastructure** | EC2, VPC, IAM Role, Security Group |
| **Vault Auth Method** | AWS IAM (`vault-java-driver`) |
| **Vault Secret Engine** | KV v2 (`apps/hello-vault-java/config`) |
| **HCP Terraform Workspace** | `demo-app-04` |

## Architecture & Authentication Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ AWS EC2 (RHEL 9)                                                                 │
│                                                                                  │
│  Spring Boot App (127.0.0.1:8080)                                                │
│    │                                                                             │
│    │ 1. Generates AWS STS signed headers                                         │
│    │    via AWS SDK for Java                                                     │
│    ▼                                                                             │
│  Vault AWS Auth Login ───────────────▶ HashiCorp Vault                           │
│                                           │                                      │
│                                           │ 2. Validates STS signature & role ARN│
│                                           │ 3. Issues short-lived Vault token    │
│                                           ▼                                      │
│  Reads KV v2 Secret   ◀─────────────── Vault KV v2 Engine                        │
│  (apps/hello-vault-java/config)                                                  │
│    │                                                                             │
│    ▼                                                                             │
│  Serves JSON response                                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. The Spring Boot application generates signed AWS STS headers using the attached EC2 IAM instance profile.
2. The `vault-java-driver` performs an AWS IAM login against Vault.
3. Vault authenticates the caller against AWS and verifies the IAM role binding.
4. Vault issues an ephemeral token scoped to `hello-vault-java-read`.
5. The application fetches `apps/hello-vault-java/config` and serves JSON responses on port 8080.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-04` workspace:

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
- Java 21 + Maven 3.9+ (for building the fat jar)
- Vault server with AWS auth method enabled and configured
- `demo-apps-vault-config` workspace applied to establish the workspace JWT and IAM policies

## Features & Key Capabilities

- **Enterprise Spring Boot 3.4**: Modern Spring Boot runtime on Java 21 LTS.
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
cp .env.example .env   # fill in local test values
export $(cat .env | xargs)
mvn spring-boot:run
```

> [!IMPORTANT]
> For local development, export a valid `VAULT_TOKEN` — the AWS IAM login flow requires EC2 instance metadata.

## License

Business Source License 1.1
