variable "vault_address" {
  description = "Vault server address. Injected from the demo-apps-vault-config workspace variable set."
  type        = string
}

variable "tfc_organization" {
  description = "HCP Terraform organization name. Used to scope JWT bound_claims to this org only."
  type        = string
  default     = "crenaud-org"
}
