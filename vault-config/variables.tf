variable "vault_address" {
  description = "Vault server address. Injected from the demo-apps-vault-config workspace variable set."
  type        = string
}

variable "tfc_organization" {
  description = "HCP Terraform organization name. Used to scope JWT bound_claims to this org only."
  type        = string
  default     = "crenaud-org"
}

# ── GitHub Organizational global variable set ─────────────────────────────────
# HCP Terraform injects these into every workspace in the org. Declared here
# with defaults to silence "undeclared variable" warnings. Not used by this
# workspace — vault-config/ makes no GitHub API calls.
variable "GH_TOKEN" {
  description = "GitHub token. Injected by the GitHub Organizational global variable set. Not used by vault-config."
  type        = string
  sensitive   = true
  default     = ""
}

variable "GH_ORGANIZATION" {
  description = "GitHub organization. Injected by the GitHub Organizational global variable set. Not used by vault-config."
  type        = string
  default     = ""
}

variable "VCS_OAUTH_TOKEN_ID" {
  description = "VCS OAuth token ID. Injected by the GitHub Organizational global variable set. Not used by vault-config."
  type        = string
  sensitive   = true
  default     = ""
}

variable "GH_PEM" {
  description = "GitHub App PEM key. Injected by the GitHub Organizational global variable set. Not used by vault-config."
  type        = string
  sensitive   = true
  default     = ""
}

variable "GH_APP_INSTALLATION_ID" {
  description = "GitHub App installation ID. Injected by the GitHub Organizational global variable set. Not used by vault-config."
  type        = string
  default     = ""
}
