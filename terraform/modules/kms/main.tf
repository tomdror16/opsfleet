# ─────────────────────────────────────────────────────────────────────────────
# KMS module
#
# Creates KMS keys that must exist BEFORE the EKS cluster is provisioned
# (EKS encryption_config references the key at cluster creation time).
# Keeping KMS in its own module avoids a circular dependency between the
# eks module (needs key ARN) and the secrets module (needs OIDC from EKS).
#
# Keys created:
#   • eks-secrets  – used by EKS control plane for envelope encryption of etcd
#   • secrets-mgr  – used by Secrets Manager to encrypt secret values at rest
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ── EKS envelope encryption key ───────────────────────────────────────────────

resource "aws_kms_key" "eks_secrets" {
  description             = "EKS envelope encryption for Kubernetes Secrets – ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${var.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEKSServiceUse"
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.cluster_name}-eks-secrets-key"
    Cluster = var.cluster_name
    Purpose = "EKS envelope encryption"
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}

# ── Secrets Manager key ───────────────────────────────────────────────────────

resource "aws_kms_key" "secrets_manager" {
  description             = "Secrets Manager encryption – ${var.cluster_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowRootFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${var.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowSecretsManagerUse"
        Effect    = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name    = "${var.cluster_name}-secrets-manager-key"
    Cluster = var.cluster_name
    Purpose = "Secrets Manager encryption"
  }
}

resource "aws_kms_alias" "secrets_manager" {
  name          = "alias/${var.cluster_name}-secrets-manager"
  target_key_id = aws_kms_key.secrets_manager.key_id
}
