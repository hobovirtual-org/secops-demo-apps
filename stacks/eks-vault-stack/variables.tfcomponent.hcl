# ---------------------------------------------------------------------------
# Stack input variables
# Values differ per deployment (dev/prod/region) — set in deployments.tfdeploy.hcl
# ---------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod, sandbox)."
  default     = "dev"
}

variable "project_name" {
  type        = string
  description = "Naming prefix for all resources."
}

variable "vault_address" {
  type        = string
  description = "Vault cluster HTTPS URL."
}

variable "vault_namespace" {
  type        = string
  description = "Vault namespace. Empty string for self-managed Vault (root namespace); 'admin' for HCP Vault Dedicated."
  default     = ""
}

# OIDC identity token — ephemeral so it does not persist in Stack state
variable "identity_token" {
  type      = string
  ephemeral = true
}

variable "aws_role_arn" {
  type        = string
  description = "IAM role ARN that the Stack assumes via OIDC (dynamic credentials)."
}

variable "node_instance_type" {
  type        = string
  description = "EKS managed node group instance type."
  default     = "t3.medium"
}

variable "desired_node_count" {
  type        = number
  description = "Desired number of EKS worker nodes."
  default     = 2
}
