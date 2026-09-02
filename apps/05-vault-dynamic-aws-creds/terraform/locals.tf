locals {
  app_name    = "vault-dynamic-aws"
  name_prefix = "${var.project_name}-${local.app_name}-${var.environment}"

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    vault_address   = var.vault_address
    vault_namespace = var.vault_namespace
    vault_role      = vault_aws_auth_backend_role.app.role
    aws_role_path   = vault_aws_secret_backend_role.demo.name
  }))
}
