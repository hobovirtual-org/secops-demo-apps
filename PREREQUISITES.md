# Prerequisites

Everything that must exist **before** you trigger a Terraform run in this repo. Follow the sections in order — each layer depends on the one above it.

---

## Layer 1 — Vault server (`secops-vault-dev`)

The Vault server is provisioned by a separate repo: [`secops-vault-dev`](https://github.com/hobovirtual-org/secops-vault-dev). This repo's workspaces are consumers of that server.

### 1.1 — Vault must be running and unsealed

```bash
export VAULT_ADDR="https://vault.christian-renaud.sbx.hashidemos.io"
export VAULT_TOKEN="<root-token-from-secops-vault-dev-init>"

vault status
# Sealed: false   ← required
```

> [!NOTE]
> This is a **self-managed Vault instance** — there is no namespace. Do not set `VAULT_NAMESPACE`. All paths are at root.

### 1.2 — JWT auth backend (one-time bootstrap, already done)

The JWT auth backend enables HCP Terraform workspaces to authenticate to Vault using short-lived JWTs — no stored tokens. This was bootstrapped once via CLI:

```bash
# Enable the JWT auth backend
vault auth enable -path=jwt jwt

# Trust HCP Terraform as the OIDC issuer
vault write auth/jwt/config \
  oidc_discovery_url="https://app.terraform.io" \
  bound_issuer="https://app.terraform.io"
```

**Verify it exists:**

```bash
vault auth list
# jwt/   jwt   ...   ← must be present
```

### 1.3 — demo-apps-vault-config JWT role (one-time bootstrap, already done)

The `demo-apps-vault-config` workspace needs its own JWT role in Vault so it can authenticate and provision roles for the app workspaces. This was created once via CLI:

```bash
# Create the provisioner policy
vault policy write demo-apps-vault-config-provisioner - <<'EOF'
# Read JWT auth backend metadata
path "sys/mounts/auth/jwt" {
  capabilities = ["read"]
}
path "sys/mounts" {
  capabilities = ["read"]
}

# JWT auth role management — one role per demo app workspace
path "auth/jwt/role/demo-app-*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Policy management — one policy per demo app workspace
path "sys/policies/acl/demo-app-*" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF

# Create the JWT role scoped to the demo-apps-vault-config workspace
curl --silent \
  --header "X-Vault-Token: $VAULT_TOKEN" \
  --request PUT \
  --data '{
    "role_type": "jwt",
    "bound_audiences": ["vault.workload.identity"],
    "bound_claims": {
      "terraform_organization_name": "crenaud-org",
      "terraform_workspace_name": "demo-apps-vault-config"
    },
    "user_claim": "terraform_run_phase",
    "token_policies": ["demo-apps-vault-config-provisioner"],
    "token_ttl": 900,
    "token_max_ttl": 900
  }' \
  "${VAULT_ADDR}/v1/auth/jwt/role/demo-apps-vault-config"

# Verify
vault read auth/jwt/role/demo-apps-vault-config
```

> [!IMPORTANT]
> If you are rebuilding this environment from scratch, these two steps **must be done before** triggering any `demo-apps-vault-config` run. All subsequent JWT roles (for `demo-app-01` through `demo-app-07`) are created automatically by that workspace.

### 1.4 — Vault AWS auth (EC2 apps 01–05)

Each EC2 app creates its own AWS auth backend and role automatically via the `_shared/vault-aws-auth` module. No manual Vault setup required.

Vault calls `sts:GetCallerIdentity` to verify the EC2 IAM identity. Ensure the Vault EC2 instance role (from `secops-vault-dev`) has no SCP blocking outbound STS calls.

### 1.5 — Vault AWS secrets engine (App 05 only)

App 05 uses the Vault AWS secrets engine to issue dynamic IAM credentials. The Vault EC2 instance role needs IAM permissions to create and delete IAM users:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "iam:CreateUser", "iam:DeleteUser",
      "iam:AttachUserPolicy", "iam:DetachUserPolicy",
      "iam:CreateAccessKey", "iam:DeleteAccessKey",
      "iam:PutUserPolicy", "iam:DeleteUserPolicy",
      "iam:ListUserPolicies", "iam:ListAttachedUserPolicies"
    ],
    "Resource": "arn:aws:iam::*:user/vault-*"
  }]
}
```

Add this to the EC2 instance role policy in `secops-vault-dev`.

---

## Layer 2 — AWS account

### 2.1 — Approved RHEL 9 AMI

Apps 01–05 launch EC2 instances from an approved RHEL 9 base AMI:

| Setting | Value |
|---|---|
| AMI owner account | `888995627335` |
| AMI name pattern | `hc-base-rhel-9-x86_64-*` |
| Region | `us-east-1` |

### 2.2 — EC2 key pair

All EC2 apps use the existing key pair named **`linux`** in the AWS account. Use the same key pair for demo apps or create a new one and update accordingly.

### 2.3 — OIDC IAM provider for HCP Terraform (all apps)

All workspaces authenticate to AWS using **OIDC dynamic credentials** (no long-lived access keys). The OIDC provider is bootstrapped once in `platform-control-workspace` via `aws-oidc.tf`. Verify it exists:

```bash
aws iam list-open-id-connect-providers | grep app.terraform.io
```

Per-workspace IAM roles are created automatically by `platform-control-workspace` using the `module-tfc-oidc-aws` private module.

---

## Layer 3 — HCP Terraform (`crenaud-org`)

All workspaces are provisioned as code by [`platform-control-workspace`](https://github.com/hobovirtual-org/platform-control-workspace). **Do not create workspaces manually** in the HCP Terraform UI.

### 3.1 — Apply platform-control-workspace

Trigger a run on `platform-control-workspace`. This creates:

- The `Security` project
- All workspace files (including `demo-apps-vault-config`, `demo-app-01`, etc.)
- Per-workspace IAM OIDC roles
- Variable sets with `TFC_VAULT_*` and `TFC_AWS_*` env vars injected

No manual variable configuration is needed — everything is wired in code.

### 3.2 — Apply demo-apps-vault-config

Once `platform-control-workspace` converges, trigger a run on **`demo-apps-vault-config`**.

This workspace runs [`vault-config/`](vault-config/) and creates:
- One Vault JWT auth role per app workspace (`demo-app-01` through `demo-app-07`)
- One scoped Vault policy per app workspace

Authentication: JWT dynamic credentials via `TFC_VAULT_PROVIDER_AUTH` (no stored token).

**This must converge before any app workspace runs.**

### 3.3 — Apply app workspaces

After `demo-apps-vault-config` is green, trigger app workspaces in any order:

| Workspace | What it creates |
|---|---|
| `demo-app-01` | KV v2 secret + AWS auth role + VPC + EC2 instance + Route53 record |
| `demo-app-02` | Same pattern, Go app |
| `demo-app-03` | Same pattern, Node.js app |
| `demo-app-04` | Same pattern, Java Spring Boot app |
| `demo-app-05` | KV v2 + AWS secrets engine + EC2 |
| `demo-app-06` | EKS cluster + Kubernetes auth + Node.js workload |
| `demo-app-07` | EKS cluster + Kubernetes auth + MERN workload |

---

## Layer 4 — Local workstation tools

| Tool | Minimum version | Purpose |
|---|---|---|
| Terraform CLI | `>= 1.9.0` | EC2 app Terraform |
| Terraform CLI | `>= 1.14.5` | Stacks CLI (use `.terraform-version`) |
| AWS CLI | `>= 2.0` | EKS kubeconfig, OIDC setup |
| kubectl | `>= 1.29` | EKS workloads |
| Helm | `>= 3.0` | Vault Agent Injector |
| vault CLI | any | Bootstrap steps + smoke-testing |

```bash
terraform version   # >= 1.9.0
aws --version       # >= 2.0
vault version
```

---

## Validation checklist

Run through this before triggering any app run:

- [ ] `vault status` returns `Sealed: false` at `https://vault.christian-renaud.sbx.hashidemos.io`
- [ ] `vault auth list` shows `jwt/` enabled
- [ ] `vault read auth/jwt/role/demo-apps-vault-config` returns the role
- [ ] `vault policy read demo-apps-vault-config-provisioner` returns the policy
- [ ] `platform-control-workspace` last run is green
- [ ] `demo-apps-vault-config` last run is green (JWT roles exist for all 7 app workspaces)
- [ ] AMI owner account `888995627335` has a matching RHEL 9 AMI in `us-east-1`
- [ ] EC2 key pair `linux` exists in the target AWS account and region
- [ ] OIDC IAM provider for `app.terraform.io` exists in the AWS account

---

## Deployment order

```
1. platform-control-workspace   ← provisions all HCP Terraform workspaces + IAM OIDC roles
2. demo-apps-vault-config       ← provisions Vault JWT roles + policies for all app workspaces
3. demo-app-01 (Python/EC2)     ← validates end-to-end: JWT auth → Vault → KV secret → EC2
4. demo-app-02 … demo-app-05    ← same pattern, different language/feature
5. demo-app-06 / demo-app-07    ← EKS + Kubernetes auth (most complex)
```

Start with App 01 and validate the full flow before moving to others.
