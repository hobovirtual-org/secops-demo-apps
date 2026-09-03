locals {
  app_name    = "hello-vault-python"
  name_prefix = "${var.project_name}-${local.app_name}-${var.environment}"

  # aws_instance.user_data expects a plain string — AWS encodes it automatically.
  # Do NOT wrap in base64encode() here; that causes double-encoding and the script is never executed.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    vault_address   = var.vault_address
    vault_namespace = var.vault_namespace
    vault_role      = module.vault_aws_auth.role_name
    secret_path     = module.vault_secret.secret_path
  })
}
