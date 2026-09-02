locals {
  app_name       = "mern-vault"
  name_prefix    = "${var.project_name}-${local.app_name}-${var.environment}"
  k8s_namespace  = "mern-vault"
  k8s_sa_name    = "mern-backend"
  vault_k8s_role = "mern-backend"
}
