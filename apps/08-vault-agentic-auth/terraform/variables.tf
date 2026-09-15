variable "project_name" {
  description = "Naming prefix for all Vault resources."
  type        = string
  default     = "demo"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox"], var.environment)
    error_message = "environment must be dev, staging, prod, or sandbox."
  }
}

variable "vault_address" {
  description = "Vault cluster URL (e.g. https://vault.example.com). Also used as the JWT audience."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace. Empty string for root. Use 'admin' for HCP Vault Dedicated."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub repo in owner/name format (e.g. hobovirtual-org/secops-demo-apps). Used to scope the JWT role trust."
  type        = string
  default     = "hobovirtual-org/secops-demo-apps"
}

variable "jwt_github_accessor" {
  description = "Accessor of the jwt-github Vault auth mount. Used to create the identity entity alias for the Agent Registry. Obtain with: vault auth list -format=json | jq '.\"jwt-github/\".accessor'. Leave empty to skip alias creation."
  type        = string
  default     = ""
}
