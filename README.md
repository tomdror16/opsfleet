# startup-eks

EKS infrastructure for the startup platform — Kubernetes 1.35 with Karpenter autoscaling,
Graviton and Spot support, full monitoring, and secrets management via AWS Secrets Manager.

## Quick start

See [`terraform/README.md`](./terraform/README.md) for the full deployment guide.

```
repo/
├── .github/workflows/terraform.yml   # CI/CD: validate → plan → apply
├── docs/pipeline-setup.md            # OIDC setup, GitHub secrets, branch protection
└── terraform/                        # All infrastructure as code
    ├── README.md                     # Full usage and developer guide
    ├── scripts/
    │   ├── bootstrap-state-backend.ps1   # One-time S3
    │   └── set-secret-values.ps1         # Write secrets to AWS Secrets Manager
    ├── examples/                         # Sample workload manifests
    └── modules/
        ├── kms/          # KMS keys (created first, no dependencies)
        ├── vpc/          # Dedicated VPC, subnets, NAT GWs
        ├── eks/          # EKS 1.35 cluster, OIDC, EBS CSI, node group
        ├── karpenter/    # Karpenter 1.11.1, NodePools (x86 + arm64)
        ├── monitoring/   # kube-prometheus-stack, Grafana, alerts
        └── secrets/      # Secrets Manager, External Secrets Operator
```
