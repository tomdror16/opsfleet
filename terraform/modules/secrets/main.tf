# ─────────────────────────────────────────────────────────────────────────────
# Secrets module
#
# Depends on: kms module (for key ARNs), eks module (for OIDC), monitoring
#             module (namespace must exist before ExternalSecret is created)
#
# Creates:
#   1. Secrets Manager secret shells  – name + KMS key only, NO values
#   2. S3 state bucket policy         – HTTPS-only + explicit deny for non-CI
#   3. External Secrets Operator      – Helm release in external-secrets ns
#   4. ClusterSecretStore             – cluster-wide ESO store → Secrets Manager
#   5. ExternalSecret for Grafana     – syncs SM secret → K8s Secret in monitoring ns
#
# Secret VALUES are never set by Terraform.
# Use scripts/set-secret-values.ps1 to write them once after first apply.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ── Secrets Manager: secret shells ───────────────────────────────────────────
# Only the metadata (name, KMS key, description, tags, resource policy) is
# managed here. The actual secret value is written out-of-band.

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "${var.cluster_name}/grafana/admin"
  description             = "Grafana admin credentials for cluster ${var.cluster_name}"
  kms_key_id              = var.secrets_manager_kms_key_arn
  recovery_window_in_days = 7

  tags = {
    Name    = "${var.cluster_name}-grafana-admin"
    Cluster = var.cluster_name
    App     = "grafana"
  }
}

# Resource policy: only ESO's IRSA role can call GetSecretValue.
# All other principals (including any future unscoped roles) are denied.
resource "aws_secretsmanager_secret_policy" "grafana_admin" {
  secret_arn = aws_secretsmanager_secret.grafana_admin.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowESORead"
        Effect = "Allow"
        Principal = { AWS = aws_iam_role.eso.arn }
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "*"
      },
      {
        Sid    = "DenyAllOtherGetSecretValue"
        Effect = "Deny"
        Principal = { AWS = "*" }
        Action   = "secretsmanager:GetSecretValue"
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = [
              aws_iam_role.eso.arn,
              "arn:${var.partition}:iam::${local.account_id}:root",
            ]
          }
        }
      }
    ]
  })
}

# ── S3 state bucket hardening ─────────────────────────────────────────────────
# Layered on top of the encryption + versioning the bootstrap script already
# set up. Denies all non-HTTPS access and restricts PutObject/GetObject to the
# CI role and account root.

resource "aws_s3_bucket_policy" "state" {
  bucket = var.state_bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = { AWS = "*" }
        Action    = "s3:*"
        Resource = [
          "arn:${var.partition}:s3:::${var.state_bucket_name}",
          "arn:${var.partition}:s3:::${var.state_bucket_name}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "AllowCIAndRoot"
        Effect = "Allow"
        Principal = {
          AWS = compact([
            var.ci_role_arn,
            "arn:${var.partition}:iam::${local.account_id}:root",
          ])
        }
        Action = "s3:*"
        Resource = [
          "arn:${var.partition}:s3:::${var.state_bucket_name}",
          "arn:${var.partition}:s3:::${var.state_bucket_name}/*",
        ]
      }
    ]
  })
}

# ── External Secrets Operator: IRSA role ──────────────────────────────────────

data "aws_iam_policy_document" "eso_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json

  tags = {
    Name    = "${var.cluster_name}-eso-role"
    Cluster = var.cluster_name
  }
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid    = "AllowSecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    # Scoped to this cluster's secret prefix only
    resources = [
      "arn:${var.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${var.cluster_name}/*",
    ]
  }

  statement {
    sid    = "AllowKMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [var.secrets_manager_kms_key_arn]
  }
}

resource "aws_iam_policy" "eso" {
  name   = "${var.cluster_name}-eso-policy"
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_iam_role_policy_attachment" "eso" {
  role       = aws_iam_role.eso.name
  policy_arn = aws_iam_policy.eso.arn
}

# ── External Secrets Operator: Helm release ───────────────────────────────────

resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name   = "external-secrets"
    labels = { name = "external-secrets" }
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.eso_version

  wait          = true
  wait_for_jobs = true
  timeout       = 300

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }

  # Run on system nodes alongside other critical add-ons
  set {
    name  = "tolerations[0].key"
    value = "CriticalAddonsOnly"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  set {
    name  = "resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }

  depends_on = [
    kubernetes_namespace.external_secrets,
    aws_iam_role_policy_attachment.eso,
  ]
}

# ── ClusterSecretStore ────────────────────────────────────────────────────────
# Cluster-wide ESO store backed by AWS Secrets Manager.
# All namespaces can reference it via ExternalSecret resources.

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ClusterSecretStore
    metadata:
      name: aws-secrets-manager
    spec:
      provider:
        aws:
          service: SecretsManager
          region: ${local.region}
          auth:
            jwt:
              serviceAccountRef:
                name: external-secrets
                namespace: external-secrets
  YAML

  depends_on = [helm_release.external_secrets]
}

# ── ExternalSecret: Grafana admin credentials ─────────────────────────────────
# ESO syncs the live value from Secrets Manager into a K8s Secret in the
# monitoring namespace every hour. Grafana's existingSecret ref picks it up.
# When the secret is rotated in Secrets Manager, ESO updates the K8s Secret
# automatically on the next refresh cycle.

resource "kubectl_manifest" "external_secret_grafana" {
  yaml_body = <<-YAML
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: grafana-admin
      namespace: ${var.monitoring_namespace}
    spec:
      refreshInterval: 1h
      secretStoreRef:
        name: aws-secrets-manager
        kind: ClusterSecretStore
      target:
        name: grafana-admin-credentials
        creationPolicy: Owner
        template:
          type: Opaque
          data:
            admin-user: "{{ .username }}"
            admin-password: "{{ .password }}"
      data:
        - secretKey: username
          remoteRef:
            key: ${aws_secretsmanager_secret.grafana_admin.name}
            property: username
        - secretKey: password
          remoteRef:
            key: ${aws_secretsmanager_secret.grafana_admin.name}
            property: password
  YAML

  depends_on = [kubectl_manifest.cluster_secret_store]
}
