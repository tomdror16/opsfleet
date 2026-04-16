# ─────────────────────────────────────────────────────────────────────────────
# Data sources
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
}

module "kms" {
  source = "./modules/kms"

  cluster_name = var.cluster_name
  partition    = local.partition
}

# VPC

module "vpc" {
  source = "./modules/vpc"

  cluster_name         = var.cluster_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}


# EKS cluster + system node group


module "eks" {
  source = "./modules/eks"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnet_ids

  # KMS envelope encryption for Kubernetes Secrets in etcd
  kms_key_arn = module.kms.eks_kms_key_arn

  managed_node_group_instance_types = var.eks_managed_node_group_instance_types
  managed_node_group_min_size       = var.eks_managed_node_group_min_size
  managed_node_group_max_size       = var.eks_managed_node_group_max_size
  managed_node_group_desired_size   = var.eks_managed_node_group_desired_size

  depends_on = [module.kms]
}

# Karpenter

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name           = module.eks.cluster_name
  cluster_endpoint       = module.eks.cluster_endpoint
  karpenter_version      = var.karpenter_version
  karpenter_namespace    = var.karpenter_namespace
  private_subnet_ids     = module.vpc.private_subnet_ids
  node_security_group_id = module.eks.node_security_group_id
  aws_region             = var.aws_region
  account_id             = local.account_id
  partition              = local.partition

  depends_on = [module.eks]
}

# Monitoring (kube-prometheus-stack + Karpenter dashboards & alerts)

module "monitoring" {
  source = "./modules/monitoring"

  cluster_name                  = module.eks.cluster_name
  monitoring_namespace          = var.monitoring_namespace
  karpenter_namespace           = var.karpenter_namespace
  kube_prometheus_stack_version = var.kube_prometheus_stack_version
  prometheus_retention          = var.prometheus_retention
  prometheus_storage_size       = var.prometheus_storage_size
  grafana_ingress_enabled       = var.grafana_ingress_enabled
  grafana_hostname              = var.grafana_hostname

  depends_on = [module.eks, module.karpenter]
}

# Secrets

module "secrets" {
  source = "./modules/secrets"

  cluster_name                = var.cluster_name
  partition                   = local.partition
  oidc_provider_arn           = module.eks.oidc_provider_arn
  oidc_provider_url           = replace(module.eks.oidc_provider_url, "https://", "")
  secrets_manager_kms_key_arn = module.kms.secrets_manager_kms_key_arn
  monitoring_namespace        = var.monitoring_namespace
  state_bucket_name           = var.state_bucket_name
  ci_role_arn                 = var.ci_role_arn
  eso_version                 = var.eso_version

  # Needs OIDC from EKS, and the monitoring namespace must exist (created by
  # the monitoring module) before the ExternalSecret can be applied.
  depends_on = [module.eks, module.monitoring]
}
