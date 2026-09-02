# 02 — Hello Vault (Go + EC2)

**Same pattern as App 01 but written in Go — demonstrates polyglot Vault integration with the official Go SDK.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Go](https://img.shields.io/badge/Go-1.23-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)

## At a Glance

| | |
|---|---|
| **Language** | Go 1.23 |
| **Infrastructure** | EC2 (RHEL 9), VPC, IAM role |
| **Vault auth method** | AWS IAM |
| **Vault secret** | KV v2 |
| **HCP Terraform workspace** | `demo-app-02-hello-vault-go` |

## How it works

Same flow as App 01. The Go binary uses `vault/api/auth/aws` to perform the IAM login, then reads the KV v2 secret using `client.KVv2(mount).Get(ctx, path)`.

## Quick Start

Set the same workspace variables as App 01 (pointing to the `demo-app-02-hello-vault-go` workspace), push to `main`, and test:

```bash
curl http://<public_ip>:8080/
curl http://<public_ip>:8080/health
```

## Local development

```bash
cd app
cp .env.example .env   # fill in values
export $(cat .env | xargs)
go run main.go
```
