# ─────────────────────────────────────────────────────────────────────────────
# Karpenter module
#
# 1. IAM role for the Karpenter controller (IRSA)
# 2. IAM role for Karpenter-provisioned nodes (instance profile)
# 3. SQS queue + EventBridge rules for interruption handling (Spot)
# 4. Karpenter Helm release (controller + CRDs)
# 5. EC2NodeClass – shared node configuration
# 6. NodePool "x86"  – on-demand + Spot x86_64 instances
# 7. NodePool "arm64" – on-demand + Spot Graviton instances
# ─────────────────────────────────────────────────────────────────────────────

# ── Controller IAM role (IRSA) ────────────────────────────────────────────────

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:${var.partition}:iam::${var.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.karpenter_namespace}:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "karpenter-controller-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json
}

# Karpenter controller needs broad EC2 permissions to launch/terminate nodes,
# describe instance types, manage launch templates, etc.
data "aws_iam_policy_document" "karpenter_controller" {
  # Allow Karpenter to provision EC2 instances
  statement {
    sid    = "AllowScopedEC2InstanceActions"
    effect = "Allow"
    resources = [
      "arn:${var.partition}:ec2:${var.aws_region}::image/*",
      "arn:${var.partition}:ec2:${var.aws_region}::snapshot/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:spot-instances-request/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:security-group/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:subnet/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:launch-template/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:capacity-reservation/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:fleet/*",
    ]
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    resources = [
      "arn:${var.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:volume/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:network-interface/*",
    ]
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedResourceCreationTagging"
    effect = "Allow"
    resources = [
      "arn:${var.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:volume/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:network-interface/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:launch-template/*",
    ]
    actions = ["ec2:CreateTags"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    resources = [
      "arn:${var.partition}:ec2:${var.aws_region}:*:instance/*",
      "arn:${var.partition}:ec2:${var.aws_region}:*:launch-template/*",
    ]
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid    = "AllowRegionalReadActions"
    effect = "Allow"
    resources = ["*"]
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "pricing:GetProducts",
      "eks:DescribeCluster",
    ]
  }

  # SQS for interruption handling
  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    resources = [aws_sqs_queue.karpenter_interruption.arn]
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
  }

  # Pass role to instances
  statement {
    sid       = "AllowPassingInstanceRole"
    effect    = "Allow"
    resources = [aws_iam_role.karpenter_node.arn]
    actions   = ["iam:PassRole"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Create instance profiles (needed for Karpenter v1+)
  statement {
    sid       = "AllowInstanceProfileActions"
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name   = "karpenter-controller-${var.cluster_name}"
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ── Node IAM role (assumed by Karpenter-provisioned EC2 instances) ─────────────

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "karpenter-node-${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "karpenter_node_eks_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow Karpenter nodes to access the cluster
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ── SQS Interruption Queue + DLQ ─────────────────────────────────────────────
# Karpenter subscribes to this queue to gracefully drain nodes before
# Spot interruptions, rebalance notifications, and instance health events.
#
# The DLQ catches any messages Karpenter fails to process (e.g. if the
# controller is down) so they can be inspected rather than silently dropped.

resource "aws_sqs_queue" "karpenter_interruption_dlq" {
  name                      = "karpenter-interruption-${var.cluster_name}-dlq"
  message_retention_seconds = 1209600 # 14 days — enough time to investigate
  sqs_managed_sse_enabled   = true

  tags = {
    Name    = "karpenter-interruption-${var.cluster_name}-dlq"
    Cluster = var.cluster_name
  }
}

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "karpenter-interruption-${var.cluster_name}"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.karpenter_interruption_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name    = "karpenter-interruption-${var.cluster_name}"
    Cluster = var.cluster_name
  }
}

data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    sid     = "AllowEventBridgeAndASG"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

# ── EventBridge rules ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "karpenter-spot-interruption-${var.cluster_name}"
  description = "Karpenter Spot interruption notices"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "karpenter-spot-interruption"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "karpenter-rebalance-${var.cluster_name}"
  description = "Karpenter rebalance recommendations"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule      = aws_cloudwatch_event_rule.rebalance.name
  target_id = "karpenter-rebalance"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "karpenter-instance-state-${var.cluster_name}"
  description = "Karpenter instance state changes"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "karpenter-instance-state"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# AWS Health scheduled-change events (e.g. instance retirement notices)
resource "aws_cloudwatch_event_rule" "health_scheduled_change" {
  name        = "karpenter-health-${var.cluster_name}"
  description = "Karpenter AWS Health scheduled change events"

  event_pattern = jsonencode({
    source        = ["aws.health"]
    "detail-type" = ["AWS Health Event"]
    detail = {
      service            = ["EC2"]
      eventTypeCategory  = ["scheduledChange"]
    }
  })
}

resource "aws_cloudwatch_event_target" "health_scheduled_change" {
  rule      = aws_cloudwatch_event_rule.health_scheduled_change.name
  target_id = "karpenter-health"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── Helm: Karpenter ───────────────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = var.karpenter_namespace
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # Wait for all pods to be healthy before continuing
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  # Pin Karpenter controller pods to the system managed node group
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
    name  = "controller.resources.requests.cpu"
    value = "500m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "512Mi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [aws_iam_role_policy_attachment.karpenter_controller]
}

# ── EC2NodeClass ──────────────────────────────────────────────────────────────
# Shared node configuration for all Karpenter NodePools.
# Uses AL2023 which supports both x86_64 and arm64.

resource "kubectl_manifest" "ec2_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      # AL2023 is the recommended AMI family – supports both architectures
      amiFamily: AL2023
      role: ${aws_iam_role.karpenter_node.name}

      # Discover subnets and security groups via tags set on the VPC resources
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${var.cluster_name}

      # Discover the latest EKS-optimised AMI automatically
      amiSelectorTerms:
        - alias: al2023@latest

      # Instance storage – use ephemeral NVMe when available
      instanceStorePolicy: RAID0

      tags:
        Name:                    karpenter-node-${var.cluster_name}
        karpenter.sh/discovery:  ${var.cluster_name}
        Environment:             poc
        ManagedBy:               Karpenter
  YAML

  depends_on = [helm_release.karpenter]
}

# ── NodePool: x86_64 ──────────────────────────────────────────────────────────

resource "kubectl_manifest" "nodepool_x86" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: x86
    spec:
      template:
        metadata:
          labels:
            node.kubernetes.io/arch-class: x86
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            # Architecture
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]

            # Capacity types: prefer Spot, fall back to On-Demand
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]

            # Instance families: modern compute-optimised x86 families
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values:
                - m7i          # 4th-gen Intel (general purpose)
                - m7i-flex     # Cost-optimised general purpose
                - m6i          # 3rd-gen Intel
                - c7i          # Compute optimised
                - c6i          # Compute optimised
                - r7i          # Memory optimised
                - t3a          # Burstable (AMD, good for dev workloads)

            # Exclude bare-metal and nano/micro to keep things schedulable
            - key: karpenter.k8s.aws/instance-size
              operator: NotIn
              values: ["nano", "micro", "metal"]

            # Spread across AZs matching the private subnets
            - key: topology.kubernetes.io/zone
              operator: In
              values: ${jsonencode(local.private_subnet_azs)}

          # Expire nodes after 7 days so they pick up the latest AMI patches
          expireAfter: 168h

      # Bin-packing: pack pods tightly to minimise node count
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s

      limits:
        cpu: "200"
        memory: 800Gi
  YAML

  depends_on = [kubectl_manifest.ec2_node_class]
}

# ── NodePool: arm64 (Graviton) ────────────────────────────────────────────────

resource "kubectl_manifest" "nodepool_arm64" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: arm64
    spec:
      template:
        metadata:
          labels:
            node.kubernetes.io/arch-class: arm64
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default

          requirements:
            # Architecture
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]

            # Capacity types
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]

            # Graviton instance families
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values:
                - m8g          # Graviton4 general purpose (latest)
                - m7g          # Graviton3 general purpose
                - c8g          # Graviton4 compute optimised
                - c7g          # Graviton3 compute optimised
                - r8g          # Graviton4 memory optimised
                - r7g          # Graviton3 memory optimised
                - t4g          # Graviton2 burstable (cheapest dev nodes)

            - key: karpenter.k8s.aws/instance-size
              operator: NotIn
              values: ["nano", "micro", "metal"]

            - key: topology.kubernetes.io/zone
              operator: In
              values: ${jsonencode(local.private_subnet_azs)}

          expireAfter: 168h

      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 30s

      limits:
        cpu: "200"
        memory: 800Gi
  YAML

  depends_on = [kubectl_manifest.ec2_node_class]
}

# ── Helpers: resolve AZ names from private subnet IDs ─────────────────────────
# This keeps NodePool zone constraints in sync with the VPC module outputs
# without hard-coding any AZ names.

data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.value
}

locals {
  private_subnet_azs = distinct([
    for s in data.aws_subnet.private : s.availability_zone
  ])
}
