variable "cluster_name" {
  description = "EKS cluster name (used for labelling)."
  type        = string
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for the monitoring stack."
  type        = string
  default     = "monitoring"
}

variable "karpenter_namespace" {
  description = "Namespace where Karpenter is installed (for ServiceMonitor)."
  type        = string
  default     = "kube-system"
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version."
  type        = string
  default     = "67.9.0"
}

variable "prometheus_retention" {
  description = "How long Prometheus retains metrics data."
  type        = string
  default     = "15d"
}

variable "prometheus_storage_size" {
  description = "Size of the Prometheus PVC (gp3 EBS volume)."
  type        = string
  default     = "50Gi"
}


variable "grafana_ingress_enabled" {
  description = "Expose Grafana via an Ingress resource (requires an ingress controller)."
  type        = bool
  default     = false
}

variable "grafana_hostname" {
  description = "Hostname for the Grafana Ingress (e.g. grafana.internal.example.com)."
  type        = string
  default     = "grafana.example.com"
}
