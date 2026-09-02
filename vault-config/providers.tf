# Vault provider — authenticates using a static admin token injected as VAULT_TOKEN
# by the demo-apps-vault-config workspace variable set in HCP Terraform.
# This is the only workspace in secops-demo-apps that uses a static token.
# All app workspaces (demo-app-01 … demo-app-07) use JWT dynamic credentials
# whose roles are provisioned here.
provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace
  # token is NOT set here — injected via VAULT_TOKEN env var from the workspace variable set
}
