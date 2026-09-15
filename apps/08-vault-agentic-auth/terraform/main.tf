# ══════════════════════════════════════════════════════════════════════════════
# App 08 — Vault Agentic Auth (Vault-only config)
#
# Story: a GitHub Actions-hosted AI agent authenticates to Vault using a
# short-lived GitHub OIDC JWT — no static secrets anywhere. Security teams
# watch the Vault UI to see the agent appear in the Agent Registry, audit
# logs of every secret it accessed, and leases that expire automatically.
#
# Infrastructure footprint: Vault only. No AWS, no containers, no databases.
# ══════════════════════════════════════════════════════════════════════════════

# ── JWT auth role — GitHub Actions agent ─────────────────────────────────────
# The shared auth/jwt mount (managed by vault-config) already trusts
# https://token.actions.githubusercontent.com as an issuer.
# This role binds the agent JWT to the ai-agent-policy.

resource "vault_jwt_auth_backend_role" "ai_agent" {
  backend   = "jwt-github"
  role_name = local.vault_jwt_role
  role_type = "jwt"

  # GitHub Actions OIDC audience
  bound_audiences = ["${var.vault_address}"]

  # Scope to this repo's main branch only — no forks, no PRs
  bound_claims_type = "string"
  bound_claims = {
    sub = "repo:${var.github_repo}:ref:refs/heads/main"
  }

  user_claim = "sub"

  token_policies = [vault_policy.ai_agent.name]
  token_ttl      = 300  # 5 minutes — one agent run
  token_max_ttl  = 300
  token_type     = "service"
}

# ── Agent policy ──────────────────────────────────────────────────────────────
# Minimal: read the demo KV secret and read its own identity.

resource "vault_policy" "ai_agent" {
  name = local.vault_policy_name

  policy = <<-EOT
    # Read the agent's demo config secret
    path "${local.vault_kv_mount}/data/${local.vault_kv_path}" {
      capabilities = ["read"]
    }

    # Read own entity (surfaces in Agent Registry UI)
    path "identity/entity/id/{{identity.entity.id}}" {
      capabilities = ["read"]
    }

    # Look up own token info (used in audit log demo)
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}

# ── KV-v2 demo secret ─────────────────────────────────────────────────────────
# The agent reads this — it's what shows up in the Vault audit log.
# Content is intentionally non-sensitive demo config.

resource "vault_mount" "kv" {
  path        = local.vault_kv_mount
  type        = "kv"
  options     = { version = "2" }
  description = "KV-v2 store for app-08 agent demo secrets"
}

resource "vault_kv_secret_v2" "agent_config" {
  mount = vault_mount.kv.path
  name  = local.vault_kv_path

  data_json = jsonencode({
    agent_name   = local.agent_entity_name
    model        = "claude-3-haiku"
    environment  = var.environment
    demo_message = "Zero static secrets. Vault issued this at runtime."
  })
}

# ── Agent Registry identity entity ───────────────────────────────────────────
# This is what appears in the Vault Enterprise Agent Registry UI.
# metadata drives the UI display: agent_type, model, status.

resource "vault_identity_entity" "ai_agent" {
  name     = local.agent_entity_name
  disabled = false
  policies = [vault_policy.ai_agent.name]

  metadata = {
    agent_type         = "ai"
    agent_name         = local.agent_entity_name
    model              = "claude-3-haiku"
    auth_method        = "github_actions_oidc"
    operational_status = "active"
    app                = "app-08"
    managed_by         = "terraform"
  }
}

# Alias links the GitHub Actions JWT sub claim to the identity entity.
# When the agent authenticates, Vault automatically associates its token
# with this entity — making it visible in the Agent Registry.

resource "vault_identity_entity_alias" "ai_agent_jwt" {
  name           = "repo:${var.github_repo}:ref:refs/heads/main"
  mount_accessor = data.vault_auth_backend.jwt_github.accessor
  canonical_id   = vault_identity_entity.ai_agent.id
}
