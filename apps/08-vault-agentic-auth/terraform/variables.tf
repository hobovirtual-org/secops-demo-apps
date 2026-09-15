variable "aws_region" {
  description = "AWS region for all resources."
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
  description = "Naming prefix for all AWS and Vault resources."
  type        = string
}

variable "vault_address" {
  description = "Vault cluster URL (e.g. https://vault.example.com)."
  type        = string
}

variable "vault_namespace" {
  description = "Vault namespace. Empty string for self-managed Vault (root namespace). Use 'admin' for HCP Vault Dedicated."
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ). Must be within vpc_cidr."
  type        = list(string)
  default     = ["10.80.1.0/24", "10.80.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ). Must be within vpc_cidr."
  type        = list(string)
  default     = ["10.80.10.0/24", "10.80.11.0/24"]
}

variable "agent_prompt" {
  description = "Default prompt sent to watsonx.ai by the agent."
  type        = string
  default     = "Summarize the zero-trust security principles in 3 bullet points."
}

variable "postgres_admin_password" {
  description = "Initial Postgres superuser password used by the Vault Database engine to manage dynamic credentials. Stored sensitive."
  type        = string
  sensitive   = true
}

variable "db_creds_ttl" {
  description = "Default TTL (in seconds) for Vault-issued dynamic Postgres credentials."
  type        = number
  default     = 3600
}

variable "db_creds_max_ttl" {
  description = "Maximum TTL (in seconds) for Vault-issued dynamic Postgres credentials."
  type        = number
  default     = 14400
}

