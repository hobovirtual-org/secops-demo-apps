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
  description = "Application HTTP endpoint (dns-based)."
  value       = "http://${var.fqdn}:8080"
}

output "app_url_ip" {
  description = "Application HTTP endpoint (direct IP fallback)."
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "dns_record" {
  description = "Route53 A record FQDN."
  value       = aws_route53_record.app.fqdn
}

output "vault_role" {
  description = "Vault AWS auth role name."
  value       = module.vault_aws_auth.role_name
}

output "vault_secret_path" {
  description = "Full Vault KV path where the secret lives."
  value       = module.vault_secret.secret_path
}
