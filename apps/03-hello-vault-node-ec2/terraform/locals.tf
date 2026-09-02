locals {
  app_name    = "hello-vault-node"
  name_prefix = "${var.project_name}-${local.app_name}-${var.environment}"

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    vault_address   = var.vault_address
    vault_namespace = var.vault_namespace
    vault_role      = module.vault_aws_auth.role_name
    secret_path     = module.vault_secret.secret_path
  }))
}
