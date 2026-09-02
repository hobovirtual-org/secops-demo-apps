# 03 — Hello Vault (Node.js + EC2)

**Hello Vault in Node.js/Express — same pattern as Apps 01 & 02, demonstrates the `node-vault` SDK with AWS IAM auth.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![Node.js](https://img.shields.io/badge/Node.js-20-1F6FEB)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-AWS%20IAM-2EA043)

## At a Glance

| | |
|---|---|
| **Language** | Node.js 20 + Express |
| **Infrastructure** | EC2 (RHEL 9), VPC, IAM role |
| **Vault auth method** | AWS IAM |
| **Vault secret** | KV v2 |
| **HCP Terraform workspace** | `demo-app-03-hello-vault-node` |

## Quick Start

Set workspace variables (same as App 01/02), push to `main`, then:

```bash
curl http://<public_ip>:8080/
curl http://<public_ip>:8080/health
```

## Local development

```bash
cd app
cp .env.example .env
npm install
export $(cat .env | xargs)
npm start
```
