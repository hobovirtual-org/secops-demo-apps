# 01 — Hello Vault (Python + EC2)

**Simplest possible Vault integration: a Flask app on EC2 that authenticates via AWS IAM auth and reads a KV v2 secret.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Python](https://img.shields.io/badge/Python-3.11-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)

## At a Glance

| | |
|---|---|
| **Language** | Python 3.11 + Flask |
| **Infrastructure** | EC2 (RHEL 9), VPC, IAM role |
| **Vault auth method** | AWS IAM |
| **Vault secret** | KV v2 |
| **HCP Terraform workspace** | `demo-app-01-hello-vault-python` |

## How it works

```
EC2 (IAM role) ──iam_login──▶ Vault (AWS auth)
                                    │
                              issue short-lived token
                                    │
                              read KV v2 secret
                                    │
                         Flask app returns JSON response
```

1. The EC2 instance calls `sts:GetCallerIdentity` using its attached IAM role.
2. Vault verifies the signed request against the bound IAM role ARN.
3. Vault issues a short-lived token with the `hello-vault-python-read` policy.
4. The app reads `apps/hello-vault-python/data/config` and returns a JSON response.

## Quick Start

### 1. Set workspace variables in HCP Terraform

```
project_name           = "demo"
ami_owner_account_id   = "123456789012"
existing_key_pair_name = "my-keypair"
allowed_cidr_blocks    = ["x.x.x.x/32"]
vault_address          = "https://vault.example.com"
vault_namespace        = "admin"
```

### 2. Trigger a run

Push to `main` or trigger manually in HCP Terraform.

### 3. Test the endpoint

```bash
curl http://<public_ip>:8080/
curl http://<public_ip>:8080/health
```

## Local development

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in values
export $(cat .env | xargs)
python app.py
```

> [!IMPORTANT]
> For local dev you need a valid `VAULT_TOKEN` exported — the AWS IAM flow only works on EC2.

## Infrastructure inputs

| Name | Description | Default | Required |
|---|---|---|---|
| `project_name` | Resource name prefix | — | yes |
| `ami_owner_account_id` | Approved AMI owner account | — | yes |
| `existing_key_pair_name` | EC2 SSH key pair | — | yes |
| `allowed_cidr_blocks` | SSH + HTTP allow list | — | yes |
| `vault_address` | Vault URL | — | yes |
| `vault_namespace` | Vault namespace | `admin` | no |
| `aws_region` | AWS region | `us-east-1` | no |
| `environment` | dev/staging/prod/sandbox | `dev` | no |
| `instance_type` | EC2 instance type | `t3.micro` | no |
