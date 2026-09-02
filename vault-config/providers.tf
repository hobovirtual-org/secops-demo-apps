# Vault provider — authenticates via HCP Terraform JWT dynamic credentials.
# TFC_VAULT_PROVIDER_AUTH=true causes HCP Terraform to exchange a signed JWT
# for a short-lived Vault token before the run starts. No stored token anywhere.
# address and auth path are injected via TFC_VAULT_ADDR / TFC_VAULT_AUTH_PATH.
provider "vault" {
  address = var.vault_address
  # No namespace — this is a self-managed Vault instance (root namespace).
  # No token — injected automatically via TFC_VAULT_PROVIDER_AUTH JWT exchange.
}
