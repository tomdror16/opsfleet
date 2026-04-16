# Innovate Inc. — Cloud Infrastructure Architecture Design

> **Cloud Provider:** AWS  
> **Region:** eu-west-1 (Ireland)  
> **Application:** Python/Flask REST API + React SPA + PostgreSQL  
> **Diagram:** [innovate-inc-architecture.drawio](./innovate-inc-architecture.drawio) *(open with [draw.io](https://app.diagrams.net))*

---

## Table of Contents

1. [High-Level Architecture Diagram](#1-high-level-architecture-diagram)
2. [Cloud Environment Structure](#2-cloud-environment-structure)
3. [Network Design](#3-network-design)
4. [Compute Platform (EKS)](#4-compute-platform-eks)
5. [Database Strategy](#5-database-strategy)
6. [Security Overview](#6-security-overview)
7. [CI/CD Pipeline](#7-cicd-pipeline)
8. [Observability](#8-observability)
9. [Cost Considerations](#9-cost-considerations)

---

## 1. High-Level Architecture Diagram

The full interactive diagram is provided in **`innovate-inc-architecture.drawio`** — open it at [app.diagrams.net](https://app.diagrams.net) for the best experience.

```
Internet Users
      │  HTTPS
      ▼
 CloudFront CDN ──(WAF)
      │
      ▼
 Application Load Balancer  [Public Subnets AZ-a / AZ-b]
      │
      ▼
┌─────────────────────────────────────────────┐
│            EKS Cluster (Private Subnets)    │
│  ┌──────────────────┐  ┌─────────────────┐  │
│  │  System Node Grp │  │  App Node Grp   │  │
│  │  (t3.medium ×2)  │  │  Flask API Pods │  │
│  │  CoreDNS, Proxy  │  │  React SPA Pods │  │
│  │  Cluster AS, ESO │  │  HPA: 2 → 50   │  │
│  └──────────────────┘  └─────────────────┘  │
└─────────────────────────────────────────────┘
      │  Port 5432 (private)
      ▼
┌─────────────────────────────────────────────┐
│     RDS PostgreSQL Multi-AZ (Private)       │
│  Primary (AZ-a) ──sync──► Standby (AZ-b)   │
│        └──async──► Read Replica             │
│        └──daily──► S3 Encrypted Backups     │
└─────────────────────────────────────────────┘

CI/CD:  GitHub → CodePipeline → CodeBuild → ECR → EKS (kubectl/Helm)
```

---

## 2. Cloud Environment Structure

### Recommendation: 4-Account AWS Organizations Strategy

| Account | Purpose | Justification |
|---|---|---|
| **Management** | Billing, SSO, SCPs, CloudTrail Org-level | Single pane of glass for governance; never run workloads here |
| **Shared Services / CI-CD** | CodePipeline, CodeBuild, ECR, Secrets Manager | Centralised artifact store; cross-account image access via ECR policies |
| **Staging** | Pre-production environment, mirror of prod | Full isolation; allows destructive testing without prod risk |
| **Production** | Live workloads, EKS, RDS, all customer data | Separate billing tracking; blast radius isolation; independent IAM |

### Why Not a Single Account?

- **Blast radius isolation:** A misconfigured IAM policy or runaway cost in CI/CD cannot affect production data.
- **Billing clarity:** Per-account cost allocation tags give Innovate Inc. clear visibility as they scale.
- **Compliance:** Sensitive user data is isolated in the Production account, making it easier to scope SOC 2 / GDPR audits.
- **SCPs (Service Control Policies):** The Management account can enforce guardrails (e.g. deny `s3:DeleteBucket` in prod) that even root users cannot override.

### AWS IAM Identity Center (SSO)

All human access is federated through IAM Identity Center — no long-lived IAM users. Developers get permission sets scoped to least-privilege roles per account.

---

## 3. Network Design

### VPC Architecture

One dedicated VPC per environment (Staging, Production), each with a **three-tier subnet model** across **two Availability Zones** for high availability.

```
VPC: 10.0.0.0/16
│
├── Public Subnets (AZ-a: 10.0.1.0/24 | AZ-b: 10.0.2.0/24)
│     Internet Gateway, ALB, NAT Gateways
│
├── Private App Subnets (AZ-a: 10.0.10.0/24 | AZ-b: 10.0.11.0/24)
│     EKS Worker Nodes (no direct internet access)
│
└── Private Data Subnets (AZ-a: 10.0.20.0/24 | AZ-b: 10.0.21.0/24)
      RDS Primary, RDS Standby, ElastiCache (future)
```

### Traffic Flow

1. **Inbound:** Users → CloudFront → WAF inspection → ALB → EKS Ingress → Flask/React pods.
2. **Outbound (nodes):** Worker nodes reach the internet via NAT Gateways placed in each public subnet (one per AZ for HA).
3. **Database access:** EKS pods communicate with RDS exclusively over the private data subnet. The Security Group on RDS only accepts port 5432 from the EKS node Security Group.

### Network Security Controls

| Control | Where Applied | Purpose |
|---|---|---|
| **WAF (AWS WAF v2)** | ALB | OWASP Top 10, rate limiting, geo-blocking |
| **Security Groups** | ALB, EKS nodes, RDS | Stateful per-resource firewall; deny-all default |
| **NACLs** | Subnet level | Stateless backstop; deny RFC-1918 cross-tier where unneeded |
| **VPC Flow Logs** | VPC | Capture all IP traffic for forensic analysis |
| **PrivateLink / VPC Endpoints** | S3, ECR, Secrets Manager, CloudWatch | Avoids NAT Gateway data charges; eliminates internet egress for AWS service calls |
| **GuardDuty** | Account-wide | ML-based threat detection on VPC Flow Logs, DNS, CloudTrail |

---

## 4. Compute Platform (EKS)

### Why EKS?

Amazon EKS (Elastic Kubernetes Service) provides a fully managed Kubernetes control plane. It removes the operational burden of patching and scaling etcd/API server while retaining full Kubernetes compatibility — critical for Innovate Inc.'s plan to scale to millions of users.

### Cluster Configuration

- **EKS Version:** Latest stable (e.g. 1.30), with managed node groups to simplify upgrades.
- **Managed Control Plane:** AWS operates the API server and etcd with a 99.95% SLA. No EC2 instances to manage for the control plane.
- **Private API Endpoint:** The Kubernetes API endpoint is private. Developers access it via AWS SSO-authenticated `aws eks update-kubeconfig` with RBAC.

### Node Groups

| Node Group | Instance Type | Capacity | Purpose |
|---|---|---|---|
| **System** | t3.medium | 2 On-Demand (fixed) | CoreDNS, kube-proxy, AWS Load Balancer Controller, Cluster Autoscaler, External Secrets Operator |
| **Application** | t3.large → t3.2xlarge | 2 On-Demand + Spot (auto-scaled) | Flask API pods, React SPA Nginx pods, Ingress NGINX |

**Spot Instances** are used for the application node group with a mixed-instance policy (multiple instance families) to minimise interruption risk while reducing compute costs by ~60-70%.

### Scaling Strategy

**Horizontal Pod Autoscaler (HPA):**
- Flask API: min 2 → max 50 pods, scale on CPU > 60% and custom `requests_per_second` metric.
- React SPA: min 2 → max 20 pods, scale on CPU > 70%.

**Cluster Autoscaler / Karpenter:**
- Karpenter is the preferred node provisioner for new clusters. It provisions right-sized nodes within seconds of a pod becoming pending, and consolidates underutilised nodes automatically.
- Node scale: min 2 → max 100 nodes (limited by service quotas; raise via AWS Support as needed).

### Resource Allocation (per pod, initial)

| Service | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|
| Flask API | 100m | 500m | 256Mi | 512Mi |
| React Nginx | 50m | 200m | 64Mi | 128Mi |

### Containerisation Strategy

**Image Building:**
- Multi-stage Dockerfiles to produce minimal images (builder stage compiles, final stage uses `python:3.12-slim` / `nginx:alpine`).
- Non-root user set in the final image. Read-only root filesystem where possible.

**Registry:** Amazon ECR (private, in the Shared Services account).
- ECR Lifecycle Policies: retain the last 10 images per environment tag; delete untagged images after 1 day.
- ECR Image Scanning (on push): blocks deployment if `CRITICAL` CVEs are found.

**Deployment:**
- Helm charts manage all Kubernetes manifests. Charts are versioned alongside application code.
- Rolling update strategy (`maxUnavailable: 0`, `maxSurge: 1`) ensures zero-downtime deployments.
- Pod Disruption Budgets (PDB) prevent simultaneous eviction of more than 1 pod per deployment.

**Secrets:** External Secrets Operator syncs secrets from AWS Secrets Manager into Kubernetes `Secret` objects. No secrets are stored in ECR images or Helm chart values files.

---

## 5. Database Strategy

### Service: Amazon RDS for PostgreSQL

**Justification for RDS over self-managed PostgreSQL:**

- Automated patching, backups, and failover — reduces operational overhead for a small startup team.
- Native Multi-AZ support provides synchronous replication and automatic failover in under 2 minutes.
- `Performance Insights` provides query-level telemetry with zero application changes.
- Scales vertically with a single API call or automatic storage scaling.

### Initial Configuration

| Parameter | Value |
|---|---|
| Engine | PostgreSQL 16 |
| Instance class | db.r7g.large (2 vCPU, 16 GB RAM) — scale up as needed |
| Storage | 100 GB gp3, autoscaling to 1 TB |
| Multi-AZ | Enabled (synchronous standby in AZ-b) |
| Encryption at rest | AWS KMS (CMK, not AWS-managed key) |
| TLS in transit | Enforced (`rds.force_ssl = 1`) |
| Parameter group | Custom: `shared_buffers = 4GB`, `max_connections = 200` |

### Backups and High Availability

**Automated Backups:**
- RDS automated backups retained for **30 days** (point-in-time recovery to any second within the window).
- Daily snapshots exported to S3 (encrypted, versioned, replicated to a second region for DR).

**Multi-AZ Failover:**
- The RDS standby is a synchronous replica in AZ-b. In the event of a primary failure, RDS performs automatic DNS failover in ~60–120 seconds. The application uses the RDS endpoint (DNS-based), so no application-side failover logic is needed.

**Read Replica (Phase 2):**
- One read replica in the same region for read-heavy analytics queries, keeping them off the primary.
- As traffic grows, promote the read replica and add additional replicas behind a `pgBouncer` connection pooler running as an EKS sidecar.

**Disaster Recovery:**

| Scenario | Recovery Method | RTO | RPO |
|---|---|---|---|
| AZ failure | Multi-AZ automatic failover | ~2 min | 0 (sync) |
| Region failure | Restore latest snapshot to new region | ~30 min | ~5 min |
| Accidental data deletion | Point-in-time restore (PITR) | ~15 min | Seconds |

**Connection Pooling:** `PgBouncer` deployed as a Kubernetes DaemonSet sidecar pattern, reducing PostgreSQL connection overhead as Flask pods scale.

---

## 6. Security Overview

### Identity & Access

- **IAM Roles for Service Accounts (IRSA):** EKS pods are granted AWS permissions via IAM roles bound to Kubernetes ServiceAccounts — no long-lived access keys in the cluster.
- **Principle of Least Privilege:** Each pod/service gets only the IAM actions it needs (e.g. Flask API gets `secretsmanager:GetSecretValue` for its own secret only).
- **Secrets rotation:** AWS Secrets Manager rotates database passwords automatically every 30 days.

### Data Protection

- **Encryption at rest:** RDS (KMS CMK), S3 buckets (SSE-KMS), EBS volumes (EKS nodes), ECR images.
- **Encryption in transit:** TLS 1.2+ enforced at ALB, CloudFront, and RDS. Internal pod-to-pod traffic optionally encrypted via mTLS (Istio or AWS App Mesh — Phase 2).
- **Sensitive data classification:** PII fields in the database are documented and access-logged via RDS Enhanced Monitoring.

### Compliance-Oriented Controls

- **AWS Config:** Continuously evaluates resource configurations against compliance rules (e.g. `restricted-ssh`, `rds-storage-encrypted`).
- **Security Hub:** Aggregates findings from GuardDuty, Inspector, Config, and Macie into a single dashboard.
- **CloudTrail:** Organisation-level trail with S3 log archival (immutable, 7-year retention) and CloudWatch Logs alerting on sensitive API calls.
- **Amazon Inspector:** Continuous ECR image scanning and EC2/Lambda vulnerability assessments.

---

## 7. CI/CD Pipeline

```
Developer → git push → GitHub
                          │  webhook
                          ▼
                    CodePipeline
                     │        │
               Source Stage   │
                          Build Stage (CodeBuild)
                              │  - pytest / unit tests
                              │  - docker build (multi-stage)
                              │  - docker push → ECR
                              │  - helm lint
                          Deploy Stage
                              │  - helm upgrade --install (Staging)
                              │  - Manual approval gate
                              │  - helm upgrade --install (Production)
```

**Key pipeline practices:**
- **Immutable image tags:** Images tagged with `git SHA` — no `latest` in production.
- **Automated testing gates:** Build fails if unit tests, SAST scan (CodeGuru / Semgrep), or ECR vulnerability scan finds critical issues.
- **Blue/Green option (Phase 2):** AWS CodeDeploy's EKS integration enables blue/green deployments with automatic rollback on CloudWatch alarm breach.
- **GitOps (Phase 2):** ArgoCD or Flux can replace the `helm upgrade` step for declarative, audit-trailed deployments.

---

## 8. Observability

| Pillar | Tool | What it covers |
|---|---|---|
| **Logs** | CloudWatch Logs (Fluent Bit DaemonSet) | All pod stdout/stderr, RDS error logs, VPC Flow Logs |
| **Metrics** | CloudWatch Container Insights + Prometheus/Grafana (Phase 2) | Node CPU/memory, pod counts, HPA scale events |
| **Tracing** | AWS X-Ray (Flask SDK integration) | Distributed request tracing across Flask → RDS |
| **Alerting** | CloudWatch Alarms → SNS → PagerDuty/Slack | CPU > 80%, error rate > 1%, DB failover events |
| **Dashboards** | CloudWatch Dashboards | Executive summary + engineering on-call dashboard |

---

## 9. Cost Considerations

Innovate Inc. starts small — the initial architecture is right-sized for low traffic but designed to scale:

| Resource | Initial Monthly Estimate (EUR) |
|---|---|
| EKS Cluster (control plane) | ~€70 |
| EC2 Node Group (2× t3.large Spot + 2× t3.medium On-Demand) | ~€80–120 |
| RDS db.r7g.large Multi-AZ | ~€250 |
| ALB | ~€25 |
| NAT Gateways (×2) | ~€70 |
| CloudFront + WAF | ~€20–50 |
| ECR, S3, CloudWatch | ~€30 |
| **Total (approx.)** | **~€545–615/month** |

**Cost optimisation levers as they grow:**
- Savings Plans (1-year) for baseline On-Demand nodes → ~30% saving.
- RDS Reserved Instance (1-year) → ~40% saving.
- Karpenter consolidation mode removes idle nodes during off-peak hours.
- S3 Intelligent-Tiering for backup buckets.

---

*Document version: 1.0 — April 2026*  
*Author: Cloud Architecture Team*  
*Diagram: `innovate-inc-architecture.drawio` (open at [app.diagrams.net](https://app.diagrams.net))*
