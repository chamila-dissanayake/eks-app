output "deployment_name" {
  value = kubernetes_deployment_v1.app.metadata[0].name
}

output "service_name" {
  value = kubernetes_service_v1.app.metadata[0].name
}

# Output the entire HPA configuration for reference
output "hpa_configuration" {
  description = "Complete HPA configuration"
  value = var.hpa.enabled ? {
    name              = kubernetes_horizontal_pod_autoscaler_v2.app[0].metadata[0].name
    target_deployment = kubernetes_horizontal_pod_autoscaler_v2.app[0].spec[0].scale_target_ref[0].name
    namespace         = kubernetes_horizontal_pod_autoscaler_v2.app[0].metadata[0].namespace
    min_replicas      = kubernetes_horizontal_pod_autoscaler_v2.app[0].spec[0].min_replicas
    max_replicas      = kubernetes_horizontal_pod_autoscaler_v2.app[0].spec[0].max_replicas
    target_cpu        = var.hpa.target_cpu_utilization
    target_memory     = var.hpa.target_memory_utilization
  } : null
}