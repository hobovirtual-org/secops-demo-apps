# 05 — Vault Dynamic AWS Credentials

**Python app on EC2 that requests short-lived IAM credentials from Vault's AWS secrets engine and uses them to call a real AWS API.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Python](https://img.shields.io/badge/Python-3.11-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)
![Vault Secrets](https://img.shields.io/badge/Vault%20Secrets-AWS%20Dynamic-7C5CD8)

## At a Glance

| | |
|---|---|
| **Language** | Python 3.11 + Flask |
| **Infrastructure** | EC2 (RHEL 9), VPC, IAM role |
| **Vault auth method** | AWS IAM |
| **Vault secret** | AWS secrets engine (dynamic IAM credentials) |
| **HCP Terraform workspace** | `demo-app-05-vault-dynamic-aws` |

## How it works

```
EC2 ──iam_login──▶ Vault AWS auth ──▶ short-lived Vault token
                                            │
                               Vault AWS secrets engine
                                            │
                          dynamic IAM user/key (TTL: 15min)
                                            │
                              boto3 S3 list_buckets call
```

1. The EC2 instance authenticates to Vault via AWS IAM auth.
2. The app calls `GET /aws/dynamic/vault-dynamic-aws/creds/<role>`.
3. Vault creates a temporary IAM user with the bound S3 read policy.
4. The app uses those credentials to call `s3:ListBuckets`.
5. When the Vault token expires, Vault revokes the IAM user automatically.

> [!IMPORTANT]
> This requires Vault to have an IAM role with permissions to create/delete IAM users. Configure the AWS secrets engine backend credentials server-side.

## Quick Start

Set workspace variables (same as App 01), push to `main`, then:

```bash
curl http://<public_ip>:8080/
```

## Local development

```bash
cd app
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
export $(cat .env | xargs)
python app.py
```
