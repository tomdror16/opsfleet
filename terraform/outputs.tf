output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (worker node subnets)."
  value       = module.vpc.private_subnet_ids
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "configure_kubectl" {
  description = "Run this command to update your local kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN assumed by Karpenter-provisioned nodes."
  value       = module.karpenter.node_role_arn
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN for the Karpenter controller (IRSA)."
  value       = module.karpenter.controller_role_arn
}

output "grafana_access_command" {
  description = "Run this to open Grafana locally via port-forward."
  value       = module.monitoring.grafana_access_command
}

output "prometheus_access_command" {
  description = "Run this to open Prometheus UI locally via port-forward."
  value       = module.monitoring.prometheus_access_command
}

output "monitoring_namespace" {
  description = "Namespace where the monitoring stack is deployed."
  value       = module.monitoring.monitoring_namespace
}

output "eks_kms_key_arn" {
  description = "ARN of the KMS key used for EKS envelope encryption."
  value       = module.kms.eks_kms_key_arn
}

output "grafana_secret_name" {
  description = "Secrets Manager secret name for Grafana admin credentials. Populate with set-secret-values.ps1."
  value       = module.secrets.grafana_secret_name
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator."
  value       = module.secrets.eso_role_arn
}

output "set_secrets_command" {
  description = "Run this script to write initial secret values to Secrets Manager."
  value       = "pwsh ./scripts/set-secret-values.ps1 -ClusterName ${var.cluster_name} -Region ${var.aws_region}"
}
