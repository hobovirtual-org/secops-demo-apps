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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-01"
  }

  user_claim = "terraform_run_phase"
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-02"
  }

  user_claim = "terraform_run_phase"
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-03"
  }

  user_claim = "terraform_run_phase"
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-04"
  }

  user_claim = "terraform_run_phase"
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-05"
  }

  user_claim = "terraform_run_phase"
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-06"
  }

  user_claim = "terraform_run_phase"
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
    path "sys/policies/acl/mern-vault-read" {
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

  bound_audiences = ["vault.workload.identity"]

  bound_claims = {
    terraform_organization_name = var.tfc_organization
    terraform_workspace_name    = "demo-app-07"
  }

  user_claim = "terraform_run_phase"
  role_type  = "jwt"
}
