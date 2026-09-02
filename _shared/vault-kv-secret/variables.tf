variable "app_name" {
  description = "Application name — used in descriptions."
  type        = string
}

variable "mount_path" {
  description = "KV v2 mount path (e.g. 'secret' or 'apps/hello-python')."
  type        = string
  default     = "secret"
}

variable "secret_path" {
  description = "Path inside the mount where the secret is stored (e.g. 'hello-python/config')."
  type        = string
}

variable "policy_name" {
  description = "Name of the read-only Vault policy to create."
  type        = string
}

variable "create_initial_secret" {
  description = "Whether to write an initial secret value. Set false when the secret is managed outside Terraform."
  type        = bool
  default     = true
}

variable "secret_data" {
  description = "Key/value pairs to store in the secret. Only used when create_initial_secret = true."
  type        = map(string)
  default     = {}
  sensitive   = true
}
