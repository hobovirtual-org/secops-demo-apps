# ---------------------------------------------------------------------------
# Org-level variables injected by the Platform global variable set into every
# workspace. These are used only by platform-control-workspace but HCP
# Terraform injects them globally via terraform.tfvars. Declaring them here
# silences the "value for undeclared variable" warnings without using them.
# ---------------------------------------------------------------------------

variable "GH_TOKEN" {
  description = "GitHub token (org-level, unused in app workspaces)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "GH_ORGANIZATION" {
  description = "GitHub organization (org-level, unused in app workspaces)."
  type        = string
  default     = ""
}

variable "VCS_OAUTH_TOKEN_ID" {
  description = "HCP Terraform VCS OAuth token ID (org-level, unused in app workspaces)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "GH_PEM" {
  description = "GitHub App PEM key (org-level, unused in app workspaces)."
  type        = string
  default     = ""
  sensitive   = true
}
