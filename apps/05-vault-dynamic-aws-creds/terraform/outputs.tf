output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "Public IP."
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "Application endpoint."
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "vault_dynamic_aws_role" {
  description = "Vault AWS secrets engine role that issues dynamic IAM credentials."
  value       = vault_aws_secret_backend_role.demo.name
}
