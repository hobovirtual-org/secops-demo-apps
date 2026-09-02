variable "app_name" {
  description = "Name of the application — used in descriptions and defaults."
  type        = string
}

variable "auth_path" {
  description = "Mount path for the AWS auth method (e.g. 'aws' or 'aws/demo')."
  type        = string
  default     = "aws"
}

variable "role_name" {
  description = "Name of the Vault AWS auth role to create."
  type        = string
}

variable "auth_type" {
  description = "AWS auth type: 'iam' (recommended) or 'ec2'."
  type        = string
  default     = "iam"

  validation {
    condition     = contains(["iam", "ec2"], var.auth_type)
    error_message = "auth_type must be 'iam' or 'ec2'."
  }
}

variable "bound_iam_principal_arns" {
  description = "List of IAM role ARNs allowed to authenticate (used when auth_type = 'iam')."
  type        = list(string)
  default     = []
}

variable "bound_iam_instance_profile_arns" {
  description = "List of IAM instance profile ARNs allowed to authenticate (used when auth_type = 'ec2')."
  type        = list(string)
  default     = []
}

variable "token_policies" {
  description = "Vault policies to attach to tokens issued by this role."
  type        = list(string)
}

variable "token_ttl" {
  description = "Default TTL for tokens issued by this role (seconds)."
  type        = number
  default     = 3600
}

variable "token_max_ttl" {
  description = "Maximum TTL for tokens issued by this role (seconds)."
  type        = number
  default     = 86400
}
