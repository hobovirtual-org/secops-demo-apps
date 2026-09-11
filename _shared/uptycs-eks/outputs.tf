output "namespace" {
  description = "Kubernetes namespace where Uptycs is installed."
  value       = kubernetes_namespace_v1.uptycs.metadata[0].name
}

output "tag_string" {
  description = "Full IBM tag string applied to the Uptycs sensor."
  value = join(",", [
    "UPDATE=${var.uptycs_update_tag}",
    "CCODE=HashiCorp",
    "UT=20A7V",
    "OWNER=${var.uptycs_owner_email}",
  ])
}

output "node_uuid_command" {
  description = "kubectl command to retrieve node UUIDs for Uptycs verification."
  value       = "kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.metadata.labels.ibm-cloud\\.kubernetes\\.io/worker-id}{\"\\t\"}{.status.nodeInfo.systemUUID}{\"\\n\"}{end}'"
}
