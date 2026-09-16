# vault-config/main.tf
#
# Provisions Vault JWT auth roles and policies that allow each HCP Terraform
# app workspace to authenticate to Vault using a short-lived JWT issued per run.
#
# Pattern (zero stored tokens for app workspaces):
#   HCP Terraform run → signed JWT → Vault JWT auth → short-lived token (scoped policy)
#
# This workspace authenticates to Vault via JWT dynamic credentials
# (TFC_VAULT_PROVIDER_AUTH=true). No stored token anywhere in the system.
#
# Run order (enforced by workspace dependency in platform-control-workspace):
#   demo-apps-vault-config  →  demo-app-01  →  demo-app-02  →  …
#
# One-time bootstrap (already done via CLI):
#   vault auth enable -path=jwt jwt
#   vault write auth/jwt/config oidc_discovery_url="https://app.terraform.io" bound_issuer="https://app.terraform.io"
#   vault policy write demo-apps-vault-config-provisioner <policy>
#   vault write auth/jwt/role/demo-apps-vault-config bound_claims={org,workspace} ...

# ── JWT auth backend (pre-existing, read-only reference) ─────────────────────
data "vault_auth_backend" "jwt" {
  path = "jwt"
}

# ── vault-config self-managed provisioner policy ──────────────────────────────
# Manages its own policy so jwt-github and future mounts never need CLI updates.
# The bootstrap token (created once via CLI) must have sys/policies/acl/* write.
resource "vault_policy" "vault_config_provisioner" {
  name = "demo-apps-vault-config-provisioner"

  policy = <<-POLICY
    # Auth backend management — enable/configure/disable auth methods
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }

    # Secrets engine management
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }

    # Policy management — includes writing this policy itself
    path "sys/policies/acl/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # HCP Terraform JWT auth (existing mount, read-only)
    path "auth/jwt/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # AWS IAM auth
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # GitHub Actions JWT auth mount
    path "auth/jwt-github/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    # Vault provider v5 namespace double-prefix workaround
    path "auth/auth/jwt-github/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # Identity — entity and alias management (for Agent Registry)
    path "identity/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
  POLICY
}

# ── AWS auth backend (singleton — shared by all EC2 app workspaces) ──────────
# Owned here so individual app workspaces don't race to create it.
# App workspaces reference it via data "vault_auth_backend" "aws" in the
# _shared/vault-aws-auth module.
resource "vault_auth_backend" "aws" {
  type        = "aws"
  path        = "aws"
  description = "AWS IAM auth — shared by all EC2 demo apps"
}

resource "vault_aws_auth_backend_client" "main" {
  backend = vault_auth_backend.aws.path
  # Vault uses its own EC2 instance profile to call STS — no static keys needed.
}

# ─────────────────────────────────────────────────────────────────────────────
# App 01 — hello-vault-python (EC2)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_01" {
  name = "demo-app-01-provisioner"

  policy = <<-POLICY
    # AWS auth backend — sys/auth/* required to enable/disable the backend
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }

    # AWS auth backend config and roles
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # KV v2 secrets engine management
    path "sys/mounts/apps/hello-vault-python" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/hello-vault-python/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # Policy management
    path "sys/policies/acl/hello-vault-python-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_01" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-01"
  token_policies = [vault_policy.demo_app_01.name]
  token_ttl      = 900 # 15 minutes — one run window
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-01:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 02 — hello-vault-go (EC2)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_02" {
  name = "demo-app-02-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/hello-vault-go" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/hello-vault-go/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/hello-vault-go-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_02" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-02"
  token_policies = [vault_policy.demo_app_02.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-02:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 03 — hello-vault-node (EC2)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_03" {
  name = "demo-app-03-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/hello-vault-node" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/hello-vault-node/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/hello-vault-node-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_03" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-03"
  token_policies = [vault_policy.demo_app_03.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-03:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 04 — hello-vault-java (EC2)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_04" {
  name = "demo-app-04-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/hello-vault-java" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/hello-vault-java/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/hello-vault-java-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_04" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-04"
  token_policies = [vault_policy.demo_app_04.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-04:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 05 — vault-dynamic-aws-creds (EC2)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_05" {
  name = "demo-app-05-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/dynamic-aws" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/dynamic-aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    # AWS secrets engine for dynamic IAM credentials
    path "sys/mounts/aws" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "aws/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/dynamic-aws-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_05" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-05"
  token_policies = [vault_policy.demo_app_05.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-05:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 06 — vault-eks-k8s-auth (EKS)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_06" {
  name = "demo-app-06-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/kubernetes/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/hello-vault-eks" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/hello-vault-eks/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/hello-vault-eks-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_06" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-06"
  token_policies = [vault_policy.demo_app_06.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-06:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# ─────────────────────────────────────────────────────────────────────────────
# App 07 — mern-vault (EKS)
# ─────────────────────────────────────────────────────────────────────────────

resource "vault_policy" "demo_app_07" {
  name = "demo-app-07-provisioner"

  policy = <<-POLICY
    path "sys/auth" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "sys/mounts" {
      capabilities = ["read"]
    }
    path "sys/mounts/auth/*" {
      capabilities = ["read", "sudo"]
    }
    path "auth/kubernetes/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/mounts/apps/mern-vault" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "apps/mern-vault/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policies/acl/mern-vault-mongodb-read" {
      capabilities = ["create", "read", "update", "delete"]
    }

    # PKI Secrets Engine & Certificate Policy Management
    path "sys/mounts/pki" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts/pki/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "pki/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
    path "sys/policies/acl/pki-issue-mern-vault" {
      capabilities = ["create", "read", "update", "delete"]
    }

    # Database Dynamic Secrets Engine & Policy Management
    path "sys/mounts/database" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts/database/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "database/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
    path "sys/policies/acl/mern-vault-database-read" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

# ─────────────────────────────────────────────────────────────────────────────
# App 08 — vault-agentic-auth (GitHub Actions agent)
#
# jwt-github auth mount bootstrap (one-time, run once by an operator):
#   vault auth enable -path=jwt-github jwt
#   vault write auth/jwt-github/config \
#     oidc_discovery_url="https://token.actions.githubusercontent.com" \
#     bound_issuer="https://token.actions.githubusercontent.com"
#
# auth/jwt cannot be reused — its bound_issuer is app.terraform.io which
# rejects GitHub JWTs at the mount level. jwt-github is a separate mount
# with a separate trust anchor, bootstrapped the same way auth/jwt was.
# ─────────────────────────────────────────────────────────────────────────────

# HCP Terraform provisioner role — lets the demo-app-08 workspace manage
# roles and resources inside the jwt-github mount.
resource "vault_jwt_auth_backend_role" "demo_app_08" {
  backend        = "jwt-github"
  role_name      = "demo-app-08"
  token_policies = [vault_policy.demo_app_08.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-08:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}

# Provisioner policy — lets the demo-app-08 workspace manage the GitHub
# JWT mount (roles, config) + KV mount + identity entities.
resource "vault_policy" "demo_app_08" {
  name = "demo-app-08-provisioner"

  policy = <<-POLICY
    # GitHub Actions JWT auth mount — full lifecycle management
    path "sys/auth/jwt-github" {
      capabilities = ["read", "sudo"]
    }
    path "sys/auth/jwt-github/*" {
      capabilities = ["create", "read", "update", "delete", "sudo"]
    }
    path "auth/jwt-github/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    # Vault provider v5 namespace double-prefix workaround
    path "auth/auth/jwt-github/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # KV-v2 demo secrets mount
    path "sys/mounts/app08/kv" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "sys/mounts/app08/kv/*" {
      capabilities = ["create", "read", "update", "delete"]
    }
    path "app08/kv/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # Identity — Agent Registry entity and alias management
    path "identity/entity" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "identity/entity/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "identity/entity-alias" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "identity/entity-alias/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # Policy management
    path "sys/policies/acl/ai-agent-policy" {
      capabilities = ["create", "read", "update", "delete"]
    }
  POLICY
}

resource "vault_jwt_auth_backend_role" "demo_app_07" {
  backend        = data.vault_auth_backend.jwt.path
  role_name      = "demo-app-07"
  token_policies = [vault_policy.demo_app_07.name]
  token_ttl      = 900
  token_max_ttl  = 900

  bound_audiences   = ["vault.workload.identity"]
  bound_claims_type = "glob"

  bound_claims = {
    sub = "organization:${var.tfc_organization}:project:Security:workspace:demo-app-07:run_phase:*"
  }

  user_claim = "terraform_full_workspace"
  role_type  = "jwt"
}
