variable "aws_region" {
  description = "AWS region to deploy resources into."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster (also used as a prefix for related resources)."
  type        = string
  default     = "startup-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.35"
}

#  VPC

variable "vpc_cidr" {
  description = "CIDR block for the dedicated VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to spread subnets across (minimum 2 recommended)."
  type        = list(string)
  default     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). Worker nodes live here."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

#  EKS 

variable "eks_managed_node_group_instance_types" {
  description = "Instance types for the system managed node group (runs Karpenter, CoreDNS, etc)."
  type        = list(string)
  default     = ["m7g.medium", "m6g.medium"]
}

variable "eks_managed_node_group_min_size" {
  description = "Minimum number of nodes in the system managed node group."
  type        = number
  default     = 2
}

variable "eks_managed_node_group_max_size" {
  description = "Maximum number of nodes in the system managed node group."
  type        = number
  default     = 3
}

variable "eks_managed_node_group_desired_size" {
  description = "Desired number of nodes in the system managed node group."
  type        = number
  default     = 2
}

#  Karpenter 

variable "karpenter_version" {
  description = "Karpenter Helm chart version."
  type        = string
  default     = "1.11.1"
}

variable "karpenter_namespace" {
  description = "Kubernetes namespace where Karpenter is installed."
  type        = string
  default     = "kube-system"
}

#  Monitoring 

variable "monitoring_namespace" {
  description = "Kubernetes namespace for the monitoring stack."
  type        = string
  default     = "monitoring"
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
  description = "EBS volume size for the Prometheus PVC."
  type        = string
  default     = "50Gi"
}

variable "grafana_ingress_enabled" {
  description = "Expose Grafana via an Ingress resource."
  type        = bool
  default     = false
}

variable "grafana_hostname" {
  description = "Hostname for the Grafana Ingress (only used when grafana_ingress_enabled = true)."
  type        = string
  default     = "grafana.example.com"
}

#  Secrets 

variable "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state. Used to harden the bucket policy."
  type        = string
  # No default — must be explicitly set to match the bucket created by bootstrap-state-backend.ps1
}

variable "ci_role_arn" {
  description = "ARN of the GitHub Actions OIDC IAM role. Granted access to the state bucket and is the only principal that can apply Terraform."
  type        = string
  # No default — set in terraform.tfvars or via TF_VAR_ci_role_arn
}

variable "eso_version" {
  description = "External Secrets Operator Helm chart version."
  type        = string
  default     = "0.14.4"
}

#  Tags 

variable "default_tags" {
  description = "Tags applied to every AWS resource via the provider default_tags block."
  type        = map(string)
  default = {
    Project     = "startup-eks"
    ManagedBy   = "Terraform"
    Environment = "poc"
  }
}
