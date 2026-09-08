variable "uptycs_helm_repo_url" {
  description = "Helm repository URL for the IBM CISO Uptycs Kubernetes chart. Obtain from the IBM Uptycs Kubernetes Guide (requires VPN)."
  type        = string
}

variable "uptycs_chart_version" {
  description = "Uptycs Helm chart version. Check the Sensor Status Page for the compliant version: https://watson2.uptycs.io"
  type        = string
}

variable "uptycs_owner_email" {
  description = "OWNER tag value — your team or personal IBM/HashiCorp email address (e.g. john.doe@ibm.com)."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.uptycs_owner_email))
    error_message = "uptycs_owner_email must be a valid email address."
  }
}

variable "uptycs_update_tag" {
  description = "UPDATE tag value — environment string per the IBM Tag Guide (e.g. PROD, NONPROD, DEV). Use NONE for non-production."
  type        = string
  default     = "NONE"

  validation {
    condition     = contains(["PROD", "NONPROD", "DEV", "NONE"], var.uptycs_update_tag)
    error_message = "uptycs_update_tag must be one of: PROD, NONPROD, DEV, NONE."
  }
}
