output "monitoring_namespace" {
  description = "Namespace where the monitoring stack is deployed."
  value       = kubernetes_namespace.monitoring.metadata[0].name
}

output "grafana_service_name" {
  description = "Kubernetes Service name for Grafana (for port-forwarding or Ingress)."
  value       = "kube-prometheus-stack-grafana"
}

output "prometheus_service_name" {
  description = "Kubernetes Service name for Prometheus."
  value       = "kube-prometheus-stack-prometheus"
}

output "alertmanager_service_name" {
  description = "Kubernetes Service name for Alertmanager."
  value       = "kube-prometheus-stack-alertmanager"
}

output "grafana_access_command" {
  description = "kubectl port-forward command to access Grafana locally."
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
}

output "prometheus_access_command" {
  description = "kubectl port-forward command to access the Prometheus UI locally."
  value       = "kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090"
}
