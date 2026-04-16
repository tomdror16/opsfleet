variable "cluster_name" {
  description = "EKS cluster name used as a prefix for all resource names and secret paths."
  type        = string
}

variable "partition" {
  description = "AWS partition (aws, aws-cn, aws-us-gov)."
  type        = string
  default     = "aws"
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (for ESO IRSA trust policy)."
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider without the https:// prefix."
  type        = string
}

variable "secrets_manager_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt Secrets Manager secrets (from kms module)."
  type        = string
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace where monitoring (Grafana) is deployed."
  type        = string
  default     = "monitoring"
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds Terraform remote state."
  type        = string
}

variable "ci_role_arn" {
  description = "ARN of the GitHub Actions OIDC role that needs access to the state bucket."
  type        = string
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "0.14.4"
}
