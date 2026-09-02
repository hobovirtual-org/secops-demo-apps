# ---------------------------------------------------------------------------
# Vault KV v2 secrets engine + policy
#
# This module:
#   1. Enables a KV v2 secrets engine at the given mount path (idempotent).
#   2. Writes an initial secret at the given path (optional — set
#      create_initial_secret = false to skip).
#   3. Creates a read-only Vault policy scoped to that secret path.
# ---------------------------------------------------------------------------

resource "vault_mount" "kv" {
  path        = var.mount_path
  type        = "kv-v2"
  description = "KV v2 secrets engine for ${var.app_name}"
}

resource "vault_kv_secret_v2" "app" {
  count = var.create_initial_secret ? 1 : 0

  mount               = vault_mount.kv.path
  name                = var.secret_path
  delete_all_versions = false

  data_json = jsonencode(var.secret_data)
}

resource "vault_policy" "read" {
  name = var.policy_name

  policy = <<-POLICY
    path "${vault_mount.kv.path}/data/${var.secret_path}" {
      capabilities = ["read"]
    }

    path "${vault_mount.kv.path}/metadata/${var.secret_path}" {
      capabilities = ["read", "list"]
    }
  POLICY
}
