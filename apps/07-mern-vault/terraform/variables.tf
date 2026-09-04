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

variable "aws_role_arn" {
  description = "IAM role ARN of the HCP Terraform OIDC role — used as the EKS access entry principal. Must be a role ARN (arn:aws:iam::...), not an assumed-role session ARN."
  type        = string
}

variable "mongodb_atlas_public_key" {
  description = "MongoDB Atlas public API key (used only if using Atlas; leave empty for in-cluster MongoDB)."
  type        = string
  default     = ""
  sensitive   = true
}
