variable "ami_owner_account_id" {
  description = "AWS account ID that owns the approved base AMI."
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDRs allowed to SSH to the instance."
  type        = list(string)
}

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

variable "existing_key_pair_name" {
  description = "Existing EC2 key pair name for SSH access."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "project_name" {
  description = "Naming prefix for all AWS resources."
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

variable "route53_zone_name" {
  description = "Public Route53 hosted zone name (e.g. christian-renaud.sbx.hashidemos.io)."
  type        = string
}

variable "fqdn" {
  description = "Fully qualified domain name for the app (e.g. hello-python.christian-renaud.sbx.hashidemos.io)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.10.0.0/16"
}
