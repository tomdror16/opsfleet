# EKS + Karpenter — Infrastructure as Code

A production-ready Terraform configuration that provisions an Amazon EKS cluster
(Kubernetes **1.35**) inside a dedicated VPC and installs **Karpenter 1.11.1** with
separate NodePools for **x86_64** and **Graviton (arm64)** workloads, using Spot
instances by default for significant cost savings.

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  AWS Account                                                         │
│                                                                      │
│  ┌─────────────────────────────── VPC (10.0.0.0/16) ─────────────┐  │
│  │                                                                │  │
│  │   Public subnets (/24 × 3 AZs)    ← NAT GWs, ALB ingress     │  │
│  │   Private subnets (/24 × 3 AZs)   ← EKS nodes (all workers)  │  │
│  │                                                                │  │
│  │  ┌──────────────────── EKS 1.35 ─────────────────────────┐   │  │
│  │  │                                                        │   │  │
│  │  │  Managed Node Group "system"  (m7g.medium / Graviton) │   │  │
│  │  │    └─ CoreDNS, kube-proxy, Karpenter controller       │   │  │
│  │  │                                                        │   │  │
│  │  │  Karpenter NodePool "x86"   → m7i, m6i, c7i, c6i …   │   │  │
│  │  │  Karpenter NodePool "arm64" → m8g, m7g, c8g, c7g …   │   │  │
│  │  │                                                        │   │  │
│  │  └────────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

### Key design decisions

| Decision | Rationale |
|---|---|
| Dedicated VPC | Clean blast radius; no IP conflicts with existing networks |
| Private worker subnets | Nodes never receive public IPs; all egress via NAT GW |
| NAT GW per AZ | Removes cross-AZ bandwidth costs and single-AZ failure risk |
| Graviton system nodes | Reduces base cluster cost; AL2023 supports arm64 natively |
| Karpenter instead of Cluster Autoscaler | Faster scale-out, bin-packing, Spot diversification, and multi-arch awareness |
| Spot-first NodePools | Up to 70–90 % cost saving vs On-Demand; Karpenter handles interruptions gracefully via SQS |
| AL2023 AMI family | AWS-supported, SELinux-enabled, containerd 2.x, works on both architectures |
| Node expiry (168 h) | Nodes are recycled weekly so they always run the latest patched AMI |

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Terraform | 1.9.0 |
| AWS CLI | 2.x, configured with credentials |
| kubectl | 1.29+ |
| helm | 3.x (only needed for manual inspection; Terraform drives installs) |

Your AWS credentials must have permissions to create VPC, EKS, IAM, SQS, and
EventBridge resources.

---

## Repository layout

```
terraform/
├── main.tf                     # Root: wires together the three modules
├── providers.tf                # AWS, Kubernetes, Helm, kubectl providers
├── variables.tf                # All input variables with defaults
├── outputs.tf                  # Useful output values
├── versions.tf                 # Provider version constraints
├── terraform.tfvars.example    # Copy → terraform.tfvars and customise
│
├── modules/
│   ├── vpc/                    # VPC, subnets, IGW, NAT GWs, route tables
│   ├── eks/                    # EKS cluster, OIDC, managed node group, add-ons
│   └── karpenter/              # IAM, SQS, EventBridge, Helm, NodeClass, NodePools
│
└── examples/
    ├── x86-deployment.yaml           # Deploy on x86_64 nodes
    ├── graviton-deployment.yaml      # Deploy on Graviton (arm64) nodes
    └── spot-preferred-deployment.yaml # Multi-arch, Spot-preferred policy
```

---

## Deployment guide

### 1. Clone and configure

```bash
git clone <your-repo>
cd terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars – at minimum set aws_region and cluster_name
```

### 2. Initialise Terraform

```bash
terraform init
```

### 3. Review the plan

```bash
terraform plan
```

The plan will create approximately **60–70 resources** including the VPC, EKS
cluster, IAM roles, SQS queue, EventBridge rules, Karpenter Helm release,
EC2NodeClass, and two NodePools.

### 4. Apply

```bash
terraform apply
```

This takes roughly **15–20 minutes** — most of the time is EKS control-plane
provisioning and the managed node group bootstrap.

### 5. Configure kubectl

```bash
# The exact command is printed as a Terraform output:
terraform output -raw configure_kubectl | bash

# Verify connectivity:
kubectl get nodes
```

You should see the 2 system nodes (Graviton, tainted `CriticalAddonsOnly`).

### 6. Verify Karpenter

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

kubectl get ec2nodeclass
kubectl get nodepool
```

---

## Destroying the infrastructure

```bash
# Delete any workloads first so Karpenter drains its nodes cleanly:
kubectl delete deployments --all -A

# Wait ~60 seconds, then:
terraform destroy
```

> **Note:** If `terraform destroy` times out on EKS node group deletion, check
> whether Karpenter-provisioned nodes are still running and terminate them via
> the EC2 console or `kubectl delete node <name>` before retrying.

---

## Developer guide — running workloads on specific hardware

### How it works

Karpenter watches for unschedulable pods and launches the cheapest EC2 instance
that satisfies all pod constraints. Developers control placement via standard
Kubernetes primitives:

| Mechanism | Use case |
|---|---|
| `nodeSelector` | Hard requirement — pod *must* land on matching node |
| `nodeAffinity` | Soft/hard preference with weighted scoring |
| `tolerations` | Required to schedule on tainted nodes |

### Run a pod on x86_64

```yaml
# Minimal addition to any pod spec:
spec:
  nodeSelector:
    kubernetes.io/arch: amd64
```

Full example:

```bash
kubectl apply -f examples/x86-deployment.yaml
kubectl get pods -o wide   # NODE column shows the assigned node
kubectl get nodes          # new x86 node appears within ~30 seconds
```

Once running, confirm the architecture:

```bash
NODE=$(kubectl get pod -l app=nginx-x86 -o jsonpath='{.items[0].spec.nodeName}')
kubectl get node $NODE -o jsonpath='{.status.nodeInfo.architecture}'
# → amd64
```

### Run a pod on Graviton (arm64)

```yaml
# Minimal addition to any pod spec:
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
```

Full example:

```bash
kubectl apply -f examples/graviton-deployment.yaml
kubectl get pods -o wide
```

Confirm the architecture:

```bash
NODE=$(kubectl get pod -l app=nginx-graviton -o jsonpath='{.items[0].spec.nodeName}')
kubectl get node $NODE -o jsonpath='{.status.nodeInfo.architecture}'
# → arm64
```

### Prefer Graviton Spot, fall back to x86

For workloads where you want the cheapest possible option across both
architectures (requires a multi-arch container image):

```bash
kubectl apply -f examples/spot-preferred-deployment.yaml
```

### Prefer On-Demand (production critical workloads)

```yaml
spec:
  nodeSelector:
    karpenter.sh/capacity-type: on-demand
    kubernetes.io/arch: arm64          # optional: pin to Graviton
```

### Using both architectures in one Deployment

Split traffic between architectures with two Deployments sharing a single
Service, or use `topologySpreadConstraints` to spread across both:

```yaml
spec:
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/arch
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app: my-app
```

> **Important:** Your container image must be a **multi-arch manifest list**
> (built with `docker buildx` or a CI pipeline that pushes both `linux/amd64`
> and `linux/arm64` layers). Images built for a single architecture will fail
> to pull on the other.

---

## Cost optimisation tips

- **Spot diversification** — both NodePools list multiple instance families so
  Karpenter can always find Spot capacity even during regional shortages.
- **Consolidation** — the `WhenEmptyOrUnderutilized` policy means Karpenter
  continuously bin-packs running pods, terminating underused nodes within 30 s.
- **Graviton for everything possible** — Graviton4 (`m8g`) offers ~20 % better
  price/performance than equivalent x86; use arm64 wherever your images support it.
- **Node expiry** — the 168 h `expireAfter` setting ensures nodes are regularly
  replaced, picking up the latest security patches automatically.

---

## Customisation reference

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `eu-west-1` | AWS region |
| `cluster_name` | `startup-eks` | EKS cluster name (also used as resource prefix) |
| `cluster_version` | `1.35` | Kubernetes version |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR |
| `availability_zones` | `[eu-west-1a/b/c]` | AZs to spread across |
| `karpenter_version` | `1.11.1` | Karpenter Helm chart version |
| `eks_managed_node_group_instance_types` | `[m7g.medium, m6g.medium]` | System node instance types |

All variables are documented in `variables.tf`.

---

## Monitoring

The `monitoring` module deploys a complete observability stack into the `monitoring` namespace.

### What gets deployed

| Component | Purpose |
|---|---|
| **Prometheus Operator** | Manages Prometheus and Alertmanager CRDs |
| **Prometheus** | Scrapes all cluster metrics; 15-day retention on a 50 Gi gp3 EBS volume |
| **Alertmanager** | Routes and deduplicates alerts (Slack/PagerDuty wiring optional) |
| **Grafana** | Dashboards; persisted on a 10 Gi gp3 volume |
| **node-exporter** | DaemonSet on every node (system + Karpenter-provisioned) |
| **kube-state-metrics** | Kubernetes object state metrics |
| **Karpenter ServiceMonitor** | Scrapes Karpenter controller `/metrics` on port 8080 |
| **Karpenter PrometheusRules** | Six actionable alerts (see below) |
| **Karpenter Grafana dashboards** | Overview, Activity, Performance (grafana.com IDs 22171–22173) |

### Accessing the UIs

```bash
# Grafana (admin / ChangeMe!Startup2025 – change this!)
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# → http://localhost:3000

# Prometheus
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090
# → http://localhost:9090

# Alertmanager
kubectl port-forward svc/kube-prometheus-stack-alertmanager -n monitoring 9093:9093
# → http://localhost:9093
```

Or get the commands from Terraform outputs:

```bash
terraform output grafana_access_command
terraform output prometheus_access_command
```

### Grafana dashboards

The following dashboards are automatically provisioned into the **Karpenter** folder in Grafana:

| Dashboard | Grafana ID | What it shows |
|---|---|---|
| Karpenter Overview | 22171 | Node pools, instance types, node counts, pod placement |
| Karpenter Activity | 22172 | Scale-up/down events, disruptions, reasoning |
| Karpenter Performance | 22173 | Interruption queue depth, controller latency, cloud provider errors |

The standard kube-prometheus-stack dashboards (Cluster Overview, Nodes, Workloads, Persistent Volumes, etc.) are also included automatically.

### Karpenter alerts

| Alert | Severity | Fires when |
|---|---|---|
| `KarpenterNodeClaimNotLaunched` | warning | NodeClaims stuck Pending for >10 min |
| `KarpenterNodeClaimLaunchErrors` | warning | Cloud provider errors in the last 5 min |
| `KarpenterHighNodeTerminationRate` | warning | >5 nodes terminated in 10 min |
| `KarpenterDisruptionFailures` | warning | Replacement NodeClaim creation failures |
| `KarpenterReconcileErrors` | warning | >10 reconcile errors in 5 min |
| `KarpenterControllerDown` | critical | `karpenter_build_info` metric absent for 5 min |

### Sending alerts to Slack / PagerDuty

Edit the `alertmanager.config` block in `modules/monitoring/main.tf`:

```yaml
receivers:
  - name: slack-critical
    slack_configs:
      - api_url: "https://hooks.slack.com/services/XXXX/YYYY/ZZZZ"
        channel: "#alerts-k8s"
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'

route:
  routes:
    - match:
        severity: critical
      receiver: slack-critical
```

### Exposing Grafana externally

```hcl
# terraform.tfvars
grafana_ingress_enabled = true
grafana_hostname        = "grafana.internal.mycompany.com"
```

This provisions an Ingress with TLS (requires nginx-ingress-controller and cert-manager in the cluster).

### Tuning storage and retention

```hcl
# terraform.tfvars
prometheus_retention    = "30d"   # keep 30 days of metrics
prometheus_storage_size = "100Gi" # larger volume for production
```

### Passing the Grafana password securely

Never commit the password to git. Use an environment variable instead:

```bash
export TF_VAR_grafana_admin_password="$(aws secretsmanager get-secret-value \
  --secret-id grafana-admin-password --query SecretString --output text)"
terraform apply
```
