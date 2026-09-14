# Org-level variable declarations — silences warnings from organization-wide
# variable sets that are not consumed by this workspace.

variable "GH_TOKEN" {
  description = "GitHub personal access token (org-level variable set, not used here)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "GH_ORGANIZATION" {
  description = "GitHub organization name (org-level variable set, not used here)."
  type        = string
  default     = ""
}

variable "VCS_OAUTH_TOKEN_ID" {
  description = "HCP Terraform VCS OAuth token ID (org-level variable set, not used here)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "GH_PEM" {
  description = "GitHub App PEM key (org-level variable set, not used here)."
  type        = string
  default     = ""
  sensitive   = true
}
