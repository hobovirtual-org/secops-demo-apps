# ---------------------------------------------------------------------------
# Uptycs Kubernetes EDR sensor — IBM CISO required installation
#
# Installs the Uptycs DaemonSet via the IBM CISO-provided Helm chart.
# Tags follow the mandatory IBM schema: UPDATE/CCODE/UT/OWNER.
#
# Prerequisites (operator steps — cannot be automated):
#   1. Download the Uptycs config secret from the IBM CISO portal
#      (requires VPN + browser): https://watson2.uptycs.io
#   2. Create the Kubernetes secret in the uptycs namespace:
#        kubectl create secret generic uptycs-config \
#          --from-file=config.json=<downloaded-file> \
#          -n uptycs
#   3. Obtain the Helm chart repository URL from the IBM Uptycs
#      Kubernetes Guide and set var.uptycs_helm_repo_url.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "uptycs" {
  metadata {
    name = "uptycs"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# The config secret must be pre-created by the operator (see prerequisites).
# This data source verifies it exists before the Helm release is attempted.
data "kubernetes_secret_v1" "uptycs_config" {
  metadata {
    name      = "uptycs-config"
    namespace = kubernetes_namespace_v1.uptycs.metadata[0].name
  }
}

resource "helm_release" "uptycs" {
  name             = "uptycs"
  namespace        = kubernetes_namespace_v1.uptycs.metadata[0].name
  repository       = var.uptycs_helm_repo_url
  chart            = "k8sosquery"
  version          = var.uptycs_chart_version
  create_namespace = false

  # Give the DaemonSet time to roll out across all nodes.
  timeout = 600
  wait    = true

  # Use the IBM CISO-provided values file as base, and override tags
  values = [
    file("${path.module}/../../apps/07-mern-vault/k8s/k8sosquery-values.yaml"),
    yamlencode({
      configmap = {
        name = "uptycs-config"
        data = {
          tags = join(",", [
            "UPDATE/${var.uptycs_update_tag}",
            "CCODE/HashiCorp",
            "UT/20A7V",
            "OWNER/${var.uptycs_owner_email}",
          ])
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.uptycs,
    data.kubernetes_secret_v1.uptycs_config,
  ]
}
