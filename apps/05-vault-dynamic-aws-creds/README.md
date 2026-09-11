# 05 — Vault Dynamic AWS Credentials

**Dynamic secrets in action: a Python application on EC2 that requests short-lived IAM credentials on demand from Vault's AWS secrets engine to call AWS APIs.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Python](https://img.shields.io/badge/Python-3.11-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)
![Vault Secrets](https://img.shields.io/badge/Vault%20Secrets-AWS%20Dynamic-7C5CD8)
![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20RHEL%209-1F6FEB)

## At a Glance

| | |
|---|---|
| **Language & Runtime** | Python 3.11 + Flask · RHEL 9 (EC2) |
| **Infrastructure** | EC2, VPC, IAM Role, Security Group |
| **Vault Auth Method** | AWS IAM (`sts:GetCallerIdentity`) |
| **Vault Secret Engine** | AWS Secrets Engine (`aws/creds/s3-reader`) |
| **HCP Terraform Workspace** | `demo-app-05` |

## Architecture & Dynamic Secret Flow

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│ AWS EC2 (RHEL 9)                                                                 │
│                                                                                  │
│  Flask App (127.0.0.1:8080)                                                      │
│    │                                                                             │
│    │ 1. Signs AWS STS request via EC2 IAM profile                                │
│    ▼                                                                             │
│  Vault AWS Auth Login ───────────────▶ HashiCorp Vault                           │
│                                           │                                      │
│                                           │ 2. Validates identity with AWS       │
│                                           │ 3. Issues short-lived token          │
│                                           ▼                                      │
│  Requests Dynamic Creds ─────────────▶ Vault AWS Secrets Engine                  │
│  (GET /aws/creds/s3-reader)               │                                      │
│                                           │ 4. Creates temporary IAM user/keys   │
│                                           │    with S3 read policy (TTL: 15min)  │
│                                           ▼                                      │
│  Receives Dynamic AWS Keys ◀────────── Returns Access Key + Secret Key           │
│    │                                                                             │
│    │ 5. Calls AWS S3 API with temporary keys                                     │
│    ▼                                                                             │
│  boto3.client('s3').list_buckets()                                               │
│    │                                                                             │
│    ▼                                                                             │
│  Serves JSON response                                                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```

1. The EC2 instance authenticates to Vault via AWS IAM auth.
2. The Flask app calls `GET /aws/creds/s3-reader` on Vault.
3. Vault creates a dynamic, short-lived IAM user with S3 read-only permissions (15-minute lease).
4. The app receives the temporary `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
5. The app uses `boto3` to call `s3:ListBuckets` and renders the output.
6. When the lease expires, Vault automatically deletes the IAM user in AWS.

## Quick Start

### 1. Configure Workspace Variables in HCP Terraform

Set the required variables in the `demo-app-05` workspace:

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
```

> [!IMPORTANT]
> This requires Vault to have an IAM role or credentials with permissions to manage IAM users (`iam:CreateUser`, `iam:CreateAccessKey`, `iam:DeleteUser`, etc.).

## Prerequisites

- Terraform `>= 1.9.0`
- AWS Account with permissions to provision EC2, VPC, and IAM roles
- Vault server with AWS secrets engine and AWS auth backend mounted and configured
- `demo-apps-vault-config` workspace applied

## Features & Key Capabilities

- **Just-In-Time Credentials**: Generates ephemeral AWS IAM credentials with automatic lease expiration and cleanup.
- **Least Privilege Access**: Temporary credentials scoped to specific IAM policy statements (S3 read-only).
- **Automated Revocation**: Vault handles complete lifecycle management and deletion of AWS credentials.
- **Zero Stored Credentials**: No long-term AWS access keys stored on instances.
- **IMDSv2 Enforced**: EC2 metadata service configured with `http_tokens = "required"`.

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
| `app_url` | Application endpoint |
| `vault_dynamic_aws_role` | Vault AWS secrets engine role that issues dynamic IAM credentials |

## Local Development

```bash
cd app
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in local test values
export $(cat .env | xargs)
python app.py
```

> [!IMPORTANT]
> For local development, export a valid `VAULT_TOKEN` — the AWS IAM login flow requires EC2 instance metadata.

## License

Business Source License 1.1
