output "eso_role_arn" {
  description = "ARN of the IAM role assumed by External Secrets Operator."
  value       = aws_iam_role.eso.arn
}

output "grafana_secret_arn" {
  description = "ARN of the Grafana admin Secrets Manager secret. Populate with set-secret-values.ps1."
  value       = aws_secretsmanager_secret.grafana_admin.arn
}

output "grafana_secret_name" {
  description = "Secrets Manager secret name for Grafana admin credentials."
  value       = aws_secretsmanager_secret.grafana_admin.name
}
