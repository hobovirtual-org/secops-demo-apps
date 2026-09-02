# 07 — MERN + Vault

**Full MERN stack on EKS — MongoDB credentials delivered by Vault Agent Injector, zero secrets in application code.**

![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.9.0-7A3FF2)
![React](https://img.shields.io/badge/React-19-1F6FEB)
![Node.js](https://img.shields.io/badge/Node.js-20-2EA043)
![MongoDB](https://img.shields.io/badge/MongoDB-7.0-2EA043)
![EKS](https://img.shields.io/badge/AWS-EKS%201.32-7C5CD8)
![Vault Auth](https://img.shields.io/badge/Vault%20Auth-Kubernetes-7C5CD8)

## At a Glance

| | |
|---|---|
| **Stack** | React 19 (Vite) + Express + Mongoose + MongoDB 7 |
| **Infrastructure** | EKS 1.32, VPC, in-cluster MongoDB StatefulSet |
| **Vault auth method** | Kubernetes (JWT ServiceAccount token) |
| **Vault secret** | KV v2 — MongoDB credentials injected by Vault Agent |
| **HCP Terraform workspace** | `demo-app-07-mern-vault` |

## Architecture

```
Browser → React (LoadBalancer:80) → Express (ClusterIP:3001) → MongoDB (Headless:27017)
                                          │
                                 Vault Agent (sidecar)
                                          │
                              /vault/secrets/config.json
                              { mongo_username, mongo_password, ... }
```

## How secrets flow

1. Terraform writes MongoDB credentials to Vault KV v2 at `apps/mern-vault/data/mongodb`.
2. Vault Agent Injector intercepts the backend pod creation.
3. The injector's init container authenticates using the pod's ServiceAccount JWT (Kubernetes auth).
4. Vault issues a short-lived token → Agent fetches the secret.
5. The secret is written to `/vault/secrets/config.json` in a shared `emptyDir` volume.
6. The Express backend reads the file at startup — no passwords in env vars or code.

## Quick Start

### 1. Set workspace variables

```
project_name    = "demo"
vault_address   = "https://vault.example.com"
vault_namespace = "admin"
```

### 2. Trigger a run, then verify

```bash
aws eks update-kubeconfig --region us-east-1 --name <cluster_name>
kubectl get pods -n mern-vault
kubectl exec -n mern-vault deploy/mern-backend -c mern-backend -- cat /vault/secrets/config.json
```

### 3. Get the frontend URL

```bash
kubectl get svc mern-frontend -n mern-vault
# Open EXTERNAL-IP in your browser
```

## Local development

```bash
# Backend
cd app/backend
cp .env.example .env
echo '{"mongo_username":"root","mongo_password":"test","mongo_host":"localhost","mongo_port":"27017","mongo_database":"merndb"}' > secrets.json
npm install && npm start

# Frontend (separate terminal)
cd app/frontend
cp .env.example .env
npm install && npm run dev
```

> [!IMPORTANT]
> For local dev, run MongoDB locally with Docker: `docker run -p 27017:27017 mongo:7`
