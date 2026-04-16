# ─────────────────────────────────────────────────────────────────────────────
# Monitoring module
#
# Deploys the full kube-prometheus-stack into the "monitoring" namespace:
#   • Prometheus Operator + Prometheus (with persistent storage via EBS)
#   • Alertmanager (with persistent storage)
#   • Grafana (with persistent storage, pre-loaded dashboards)
#   • node-exporter DaemonSet (all nodes, including Karpenter ones)
#   • kube-state-metrics
#
# Karpenter-specific additions:
#   • ServiceMonitor that scrapes Karpenter controller metrics
#   • Grafana dashboards: Karpenter Overview, Activity, Performance (mixin IDs)
#   • PrometheusRule with critical Karpenter alerts
#
# Storage:
#   • Prometheus   – gp3 EBS, configurable retention + size
#   • Alertmanager – gp3 EBS
#   • Grafana      – gp3 EBS
# ─────────────────────────────────────────────────────────────────────────────

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name   = var.monitoring_namespace
    labels = { name = var.monitoring_namespace }
  }
}


# ── gp3 StorageClass ──────────────────────────────────────────────────────────
# gp3 is ~20 % cheaper and faster than the default gp2.
# Must exist before the Helm chart is installed so PVCs bind immediately.

resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

# Demote gp2 so it is no longer the default StorageClass.
# lifecycle.ignore_changes prevents failures on clusters where gp2
# doesn't exist or has already been demoted externally.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }
  force = true
  lifecycle {
    ignore_changes = [annotations]
  }
  depends_on = [kubernetes_storage_class.gp3]
}

# ── kube-prometheus-stack ─────────────────────────────────────────────────────

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version

  wait          = true
  wait_for_jobs = true
  timeout       = 600

  values = [
    yamlencode({
      prometheusOperator = {
        tolerations = [
          { key = "CriticalAddonsOnly", operator = "Exists", effect = "NoSchedule" }
        ]
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      prometheus = {
        prometheusSpec = {
          # Pick up ALL ServiceMonitors/PodMonitors/PrometheusRules in the cluster
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false

          retention = var.prometheus_retention
          replicas  = 1

          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = var.prometheus_storage_size } }
              }
            }
          }

          resources = {
            requests = { cpu = "500m", memory = "2Gi" }
            limits   = { cpu = "2000m", memory = "4Gi" }
          }
        }
      }

      alertmanager = {
        alertmanagerSpec = {
          replicas = 1
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources        = { requests = { storage = "10Gi" } }
              }
            }
          }
          resources = {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
        }
        # Minimal config — extend for Slack/PagerDuty (see README)
        config = {
          global = { resolve_timeout = "5m" }
          route = {
            group_by        = ["alertname", "namespace"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "12h"
            receiver        = "null"
            routes          = [{ match = { alertname = "Watchdog" }, receiver = "null" }]
          }
          receivers = [{ name = "null" }]
        }
      }

      grafana = {
        # Password is managed by External Secrets Operator (ESO).
        # ESO syncs it from AWS Secrets Manager into the K8s Secret
        # "grafana-admin-credentials" in this namespace. Run set-secret-values.ps1
        # after first apply to write the initial value to Secrets Manager.
        admin = {
          existingSecret = "grafana-admin-credentials"
          userKey        = "admin-user"
          passwordKey    = "admin-password"
        }
        persistence = {
          enabled          = true
          storageClassName = "gp3"
          size             = "10Gi"
        }
        resources = {
          requests = { cpu = "100m", memory = "256Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        sidecar = {
          dashboards = {
            enabled          = true
            label            = "grafana_dashboard"
            searchNamespace  = "ALL"
            folderAnnotation = "grafana_folder"
            provider         = { foldersFromFilesStructure = true }
          }
          datasources = { enabled = true }
        }
        "grafana.ini" = {
          server = {
            root_url = var.grafana_ingress_enabled ? "https://${var.grafana_hostname}" : "%(protocol)s://%(domain)s:%(http_port)s/"
          }
          "auth.anonymous" = { enabled = false }
        }
        ingress = var.grafana_ingress_enabled ? {
          enabled          = true
          ingressClassName = "nginx"
          annotations      = { "nginx.ingress.kubernetes.io/ssl-redirect" = "true" }
          hosts            = [var.grafana_hostname]
          tls              = [{ hosts = [var.grafana_hostname], secretName = "grafana-tls" }]
        } : {
          enabled          = false
          ingressClassName = null
          annotations      = {}
          hosts            = []
          tls              = []
        }
      }

      "prometheus-node-exporter" = {
        tolerations = [{ operator = "Exists" }]   # run on ALL nodes
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "100m", memory = "128Mi" }
        }
      }

      "kube-state-metrics" = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { cpu = "200m", memory = "256Mi" }
        }
      }

      defaultRules = {
        create = true
        rules = {
          alertmanager              = true
          etcd                      = false  # Not accessible in managed EKS
          configReloaders           = true
          general                   = true
          kubeApiserverAvailability = true
          kubeApiserverBurnrate     = true
          kubeApiserverHistogram    = true
          kubeApiserverSlos         = true
          kubeControllerManager     = false  # Managed by AWS
          kubePrometheusGeneral     = true
          kubePrometheusNodeRecording = true
          kubernetesApps            = true
          kubernetesResources       = true
          kubernetesStorage         = true
          kubernetesSystem          = true
          kubeSchedulerAlerting     = false  # Managed by AWS
          kubeSchedulerRecording    = false
          kubeStateMetrics          = true
          network                   = true
          node                      = true
          nodeExporterAlerting      = true
          nodeExporterRecording     = true
          prometheus                = true
          prometheusOperator        = true
        }
      }

      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeEtcd              = { enabled = false }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    kubernetes_storage_class.gp3,
  ]
}

# ── Karpenter ServiceMonitor ──────────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_service_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: karpenter
      namespace: ${var.monitoring_namespace}
      labels:
        app.kubernetes.io/name: karpenter
        release: kube-prometheus-stack
    spec:
      namespaceSelector:
        matchNames:
          - ${var.karpenter_namespace}
      selector:
        matchLabels:
          app.kubernetes.io/name: karpenter
      endpoints:
        - port: http-metrics
          path: /metrics
          interval: 30s
  YAML

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── Karpenter PrometheusRule ───────────────────────────────────────────────────

resource "kubectl_manifest" "karpenter_alerts" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: karpenter-alerts
      namespace: ${var.monitoring_namespace}
      labels:
        release: kube-prometheus-stack
    spec:
      groups:
        - name: karpenter.provisioning
          interval: 1m
          rules:
            - alert: KarpenterNodeClaimNotLaunched
              expr: karpenter_nodeclaims_current{state="Pending"} > 0
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "Karpenter NodeClaim pending >10 min"
                description: "NodePool {{ $labels.nodepool }} has {{ $value }} NodeClaims stuck Pending."

            - alert: KarpenterCloudProviderErrors
              expr: increase(karpenter_cloudprovider_errors_total[5m]) > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Karpenter cloud provider errors"
                description: "{{ $value }} cloud provider errors in 5 min (controller={{ $labels.controller }})."

            - alert: KarpenterHighNodeTerminationRate
              expr: increase(karpenter_nodeclaims_terminated_total[10m]) > 5
              for: 0m
              labels:
                severity: warning
              annotations:
                summary: "High Karpenter node termination rate"
                description: ">5 NodeClaims terminated in 10 min on NodePool {{ $labels.nodepool }}."

            - alert: KarpenterDisruptionReplacementFailures
              expr: increase(karpenter_disruption_replacement_nodeclaim_failures_total[5m]) > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Karpenter disruption replacement failures"
                description: "Failed to replace NodeClaims during disruption (reason={{ $labels.reason }})."

        - name: karpenter.controller
          interval: 1m
          rules:
            - alert: KarpenterReconcileErrors
              expr: increase(controller_runtime_reconcile_errors_total{controller=~".*karpenter.*"}[5m]) > 10
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Karpenter reconcile errors elevated"
                description: "Controller {{ $labels.controller }} has {{ $value }} reconcile errors in 5 min."

            - alert: KarpenterControllerDown
              expr: absent(karpenter_build_info)
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Karpenter controller is down"
                description: "karpenter_build_info absent — controller may be down or unreachable."
  YAML

  depends_on = [helm_release.kube_prometheus_stack]
}

# ── Grafana dashboards (one ConfigMap per dashboard) ──────────────────────────
# The Grafana sidecar watches for ConfigMaps labelled grafana_dashboard=1 and
# imports them. We embed stub JSON with gnetId so Grafana fetches the full
# dashboard from grafana.com at startup.

resource "kubernetes_config_map" "grafana_karpenter_overview" {
  metadata {
    name        = "grafana-karpenter-overview"
    namespace   = var.monitoring_namespace
    labels      = { grafana_dashboard = "1" }
    annotations = { grafana_folder = "Karpenter" }
  }
  data = {
    "karpenter-overview.json" = jsonencode({
      title = "Karpenter / Overview", uid = "karp-overview",
      tags = ["karpenter"], schemaVersion = 38, gnetId = 22171,
      refresh = "1m", panels = [], templating = { list = [] }, annotations = { list = [] }
    })
  }
  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "grafana_karpenter_activity" {
  metadata {
    name        = "grafana-karpenter-activity"
    namespace   = var.monitoring_namespace
    labels      = { grafana_dashboard = "1" }
    annotations = { grafana_folder = "Karpenter" }
  }
  data = {
    "karpenter-activity.json" = jsonencode({
      title = "Karpenter / Activity", uid = "karp-activity",
      tags = ["karpenter"], schemaVersion = 38, gnetId = 22172,
      refresh = "1m", panels = [], templating = { list = [] }, annotations = { list = [] }
    })
  }
  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "grafana_karpenter_performance" {
  metadata {
    name        = "grafana-karpenter-performance"
    namespace   = var.monitoring_namespace
    labels      = { grafana_dashboard = "1" }
    annotations = { grafana_folder = "Karpenter" }
  }
  data = {
    "karpenter-performance.json" = jsonencode({
      title = "Karpenter / Performance", uid = "karp-perf",
      tags = ["karpenter"], schemaVersion = 38, gnetId = 22173,
      refresh = "1m", panels = [], templating = { list = [] }, annotations = { list = [] }
    })
  }
  depends_on = [helm_release.kube_prometheus_stack]
}

# ── PodMonitor for kube-proxy ─────────────────────────────────────────────────

resource "kubectl_manifest" "kube_proxy_pod_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: kube-proxy
      namespace: ${var.monitoring_namespace}
      labels:
        release: kube-prometheus-stack
    spec:
      jobLabel: kube-proxy
      namespaceSelector:
        matchNames:
          - kube-system
      selector:
        matchLabels:
          k8s-app: kube-proxy
      podMetricsEndpoints:
        - port: metrics
          interval: 30s
          path: /metrics
  YAML

  depends_on = [helm_release.kube_prometheus_stack]
}
