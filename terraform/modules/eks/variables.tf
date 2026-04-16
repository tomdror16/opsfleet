variable "cluster_name"    { type = string }
variable "cluster_version" { type = string }
variable "vpc_id"          { type = string }
variable "private_subnets" { type = list(string) }
variable "partition" {
  type    = string
  default = "aws"
}

variable "cluster_log_retention_days" {
  description = "CloudWatch log retention for EKS control-plane logs (days)."
  type        = number
  default     = 30
}

variable "managed_node_group_instance_types" { type = list(string) }
variable "managed_node_group_min_size"       { type = number }
variable "managed_node_group_max_size"       { type = number }
variable "managed_node_group_desired_size"   { type = number }

variable "kms_key_arn" {
  description = "ARN of the KMS key for EKS envelope encryption of Kubernetes Secrets. Empty string disables encryption."
  type        = string
  default     = ""
}
