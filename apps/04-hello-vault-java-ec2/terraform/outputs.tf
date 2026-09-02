output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP of the EC2 instance."
  value       = aws_instance.app.public_ip
}

output "ssh_command" {
  description = "Example SSH command."
  value       = "ssh -i linux.pem ec2-user@${aws_instance.app.public_ip}"
}

output "app_url" {
  description = "Application HTTP endpoint."
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "vault_role" {
  description = "Vault AWS auth role name."
  value       = module.vault_aws_auth.role_name
}

output "vault_secret_path" {
  description = "Full Vault KV path where the secret lives."
  value       = module.vault_secret.secret_path
}
