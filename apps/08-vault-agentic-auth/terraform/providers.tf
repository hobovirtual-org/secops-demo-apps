provider "vault" {
  address   = var.vault_address
  namespace = var.vault_namespace != "" ? var.vault_namespace : null
}
