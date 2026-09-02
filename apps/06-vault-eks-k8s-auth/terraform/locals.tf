locals {
  app_name       = "vault-eks-k8s-auth"
  name_prefix    = "${var.project_name}-${local.app_name}-${var.environment}"
  k8s_namespace  = "hello-vault"
  k8s_sa_name    = "hello-vault"
  vault_k8s_role = "hello-vault-node"
}
