variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox"], var.environment)
    error_message = "environment must be dev, staging, prod, or sandbox."
  }
}

variable "project_name" {
  description = "Naming prefix."
  type        = string
}

variable "vault_address" {
  description = "Vault cluster URL."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace. Empty string for self-managed Vault (root namespace). Use 'admin' for HCP Vault Dedicated."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.30.0.0/16"
}

variable "node_instance_type" {
  description = "EKS node instance type."
  type        = string
  default     = "t3.medium"
}

variable "desired_node_count" {
  description = "Desired EKS node count."
  type        = number
  default     = 2
}

variable "developer_role_arns" {
  description = "List of IAM role ARNs (arn:aws:iam::...) to grant EKS cluster admin access for kubectl. Must be role ARNs, not assumed-role session ARNs."
  type        = list(string)
  default     = []
}

variable "mongodb_atlas_public_key" {
  description = "MongoDB Atlas public API key (used only if using Atlas; leave empty for in-cluster MongoDB)."
  type        = string
  default     = ""
  sensitive   = true
}

# ── Uptycs EDR sensor ────────────────────────────────────────────────────

variable "uptycs_helm_repo_url" {
  description = "Helm repository URL for the IBM CISO Uptycs chart. Obtain from the IBM Uptycs Kubernetes Guide (VPN required)."
  type        = string
}

variable "uptycs_chart_version" {
  description = "Uptycs Helm chart version. Check the Sensor Status Page for the compliant version."
  type        = string
}

variable "uptycs_owner_email" {
  description = "OWNER tag — team or personal IBM/HashiCorp contact email (e.g. john.doe@ibm.com)."
  type        = string
}

variable "uptycs_update_tag" {
  description = "UPDATE tag per IBM Tag Guide. Use NONE for non-production."
  type        = string
  default     = "NONE"
}
