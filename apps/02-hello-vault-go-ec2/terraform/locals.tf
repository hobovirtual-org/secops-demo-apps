locals {
  app_name    = "hello-vault-go"
  name_prefix = "${var.project_name}-${local.app_name}-${var.environment}"

  # Do NOT wrap in base64encode() — AWS encodes user_data automatically.
  # Double-encoding causes cloud-init to silently skip the script.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    vault_address   = var.vault_address
    vault_namespace = var.vault_namespace
    vault_role      = module.vault_aws_auth.role_name
    secret_path     = module.vault_secret.secret_path
    aws_region      = var.aws_region
  })
}
