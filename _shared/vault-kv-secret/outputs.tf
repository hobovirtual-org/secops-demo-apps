output "mount_path" {
  description = "Mount path of the KV v2 engine."
  value       = vault_mount.kv.path
}

output "secret_path" {
  description = "Full KV path of the secret (mount/data/path)."
  value       = "${vault_mount.kv.path}/data/${var.secret_path}"
}

output "policy_name" {
  description = "Name of the read-only policy created for this secret."
  value       = vault_policy.read.name
}
