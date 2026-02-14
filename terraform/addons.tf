locals {
  argocd_repo_url_trimmed = trimspace(var.argocd_app_repo_url)
  argocd_repo_configured  = local.argocd_repo_url_trimmed != ""

  argocd_repo_secret_data = merge(
    {
      type = "git"
      url  = local.argocd_repo_url_trimmed
    },
    var.argocd_repo_username != "" ? { username = var.argocd_repo_username } : {},
    var.argocd_repo_password != "" ? { password = var.argocd_repo_password } : {},
    var.argocd_repo_ssh_private_key != "" ? { sshPrivateKey = var.argocd_repo_ssh_private_key } : {}
  )
}

resource "kubernetes_namespace" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  metadata {
    name = var.argocd_namespace
  }
}

resource "helm_release" "loki_stack" {
  count = var.loki_enabled ? 1 : 0

  name             = "loki-stack"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      loki = {
        persistence = {
          enabled          = true
          storageClassName = var.monitoring_storage_class
          accessModes      = ["ReadWriteOnce"]
          size             = var.loki_persistence_size
        }
      }
      promtail = {
        enabled = true
      }
      grafana = {
        enabled = false
      }
      fluent-bit = {
        enabled = false
      }
      filebeat = {
        enabled = false
      }
      logstash = {
        enabled = false
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring
  ]
}

resource "kubernetes_config_map" "grafana_loki_datasource" {
  count = var.loki_enabled ? 1 : 0

  metadata {
    name      = "grafana-loki-datasource"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = <<-EOT
      apiVersion: 1
      datasources:
        - name: Loki
          uid: loki
          type: loki
          access: proxy
          url: http://loki-stack.monitoring.svc.cluster.local:3100
          isDefault: false
          editable: true
          jsonData:
            maxLines: 2000
    EOT
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki_stack
  ]
}
resource "kubernetes_config_map" "grafana_logs_dashboards" {
  count = var.loki_enabled ? 1 : 0

  metadata {
    name      = "terraria-logs-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "terraria-logs-overview.json" = <<-EOT
      {
        "title": "Terraria Logs Overview",
        "schemaVersion": 39,
        "version": 1,
        "editable": true,
        "style": "dark",
        "tags": ["terraria", "logs", "loki"],
        "time": {"from": "now-6h", "to": "now"},
        "annotations": {"list": []},
        "templating": {
          "list": [
            {
              "name": "namespace",
              "label": "Namespace",
              "type": "query",
              "datasource": {"type": "loki", "uid": "loki"},
              "query": {"query": "label_values(namespace)", "refId": "LokiNamespaceVar"},
              "refresh": 1,
              "includeAll": true,
              "multi": true,
              "current": {"selected": true, "text": "All", "value": "$__all"}
            },
            {
              "name": "pod",
              "label": "Pod",
              "type": "query",
              "datasource": {"type": "loki", "uid": "loki"},
              "query": {"query": "label_values({namespace=~\"$namespace\"}, pod)", "refId": "LokiPodVar"},
              "refresh": 2,
              "includeAll": true,
              "multi": true,
              "current": {"selected": true, "text": "All", "value": "$__all"}
            },
            {
              "name": "container",
              "label": "Container",
              "type": "query",
              "datasource": {"type": "loki", "uid": "loki"},
              "query": {"query": "label_values({namespace=~\"$namespace\", pod=~\"$pod\"}, container)", "refId": "LokiContainerVar"},
              "refresh": 2,
              "includeAll": true,
              "multi": true,
              "current": {"selected": true, "text": "All", "value": "$__all"}
            },
            {
              "name": "search",
              "label": "Text Filter",
              "type": "textbox",
              "query": ""
            }
          ]
        },
        "panels": [
          {
            "id": 1,
            "type": "logs",
            "title": "Filtered Logs",
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
              {
                "refId": "A",
                "expr": "{namespace=~\"$namespace\", pod=~\"$pod\", container=~\"$container\"} |= \"$search\"",
                "queryType": "range"
              }
            ],
            "options": {
              "dedupStrategy": "none",
              "enableLogDetails": true,
              "prettifyLogMessage": false,
              "showLabels": false,
              "showTime": true,
              "sortOrder": "Descending",
              "wrapLogMessage": true
            },
            "gridPos": {"h": 14, "w": 24, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "logs",
            "title": "Terraria Namespace Logs",
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
              {
                "refId": "A",
                "expr": "{namespace=\"terraria\"}",
                "queryType": "range"
              }
            ],
            "options": {
              "dedupStrategy": "none",
              "enableLogDetails": true,
              "showLabels": false,
              "showTime": true,
              "sortOrder": "Descending",
              "wrapLogMessage": true
            },
            "gridPos": {"h": 10, "w": 8, "x": 0, "y": 14}
          },
          {
            "id": 3,
            "type": "logs",
            "title": "Argo CD Namespace Logs",
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
              {
                "refId": "A",
                "expr": "{namespace=\"argocd\"}",
                "queryType": "range"
              }
            ],
            "options": {
              "dedupStrategy": "none",
              "enableLogDetails": true,
              "showLabels": false,
              "showTime": true,
              "sortOrder": "Descending",
              "wrapLogMessage": true
            },
            "gridPos": {"h": 10, "w": 8, "x": 8, "y": 14}
          },
          {
            "id": 4,
            "type": "logs",
            "title": "Monitoring Namespace Logs",
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
              {
                "refId": "A",
                "expr": "{namespace=\"monitoring\"}",
                "queryType": "range"
              }
            ],
            "options": {
              "dedupStrategy": "none",
              "enableLogDetails": true,
              "showLabels": false,
              "showTime": true,
              "sortOrder": "Descending",
              "wrapLogMessage": true
            },
            "gridPos": {"h": 10, "w": 8, "x": 16, "y": 14}
          },
          {
            "id": 5,
            "type": "timeseries",
            "title": "Top Pods by Log Volume (5m)",
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
              {
                "refId": "A",
                "expr": "topk(10, sum by (namespace, pod) (count_over_time({namespace=~\"terraria|argocd|monitoring\"}[5m])))"
              }
            ],
            "gridPos": {"h": 8, "w": 24, "x": 0, "y": 24}
          }
        ]
      }
    EOT
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki_stack,
    kubernetes_config_map.grafana_loki_datasource
  ]
}

resource "helm_release" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = kubernetes_namespace.argocd[0].metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      server = {
        service = {
          type         = "NodePort"
          nodePortHttp = var.argocd_node_port
        }
      }
      configs = {
        params = {
          "server.insecure" = true
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd
  ]
}

resource "kubernetes_secret" "argocd_repository" {
  count = var.argocd_enabled && local.argocd_repo_configured ? 1 : 0

  metadata {
    name      = "argocd-repo-${substr(sha1(local.argocd_repo_url_trimmed), 0, 8)}"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = local.argocd_repo_secret_data
  type = "Opaque"

  depends_on = [
    helm_release.argocd
  ]
}

resource "kubernetes_persistent_volume_claim" "terraria_backups" {
  count = var.terraria_backup_enabled ? 1 : 0

  metadata {
    name      = "terraria-backups"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = var.terraria_backup_pvc_size
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "terraria_world_backup" {
  count = var.terraria_backup_enabled ? 1 : 0

  metadata {
    name      = "terraria-world-backup"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  spec {
    schedule                      = var.terraria_backup_schedule
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 2

    job_template {
      metadata {}

      spec {
        template {
          metadata {}

          spec {
            restart_policy = "OnFailure"

            container {
              name    = "backup"
              image   = "alpine:3.20"
              command = ["sh", "-c"]
              args = [
                "set -eu; ts=$(date +%Y%m%d-%H%M%S); tar -czf /backups/world-$${ts}.tar.gz -C /config .; ls -1t /backups/world-*.tar.gz | tail -n +$(( $${RETENTION_COUNT} + 1 )) | xargs -r rm -f"
              ]

              env {
                name  = "RETENTION_COUNT"
                value = tostring(var.terraria_backup_retention_count)
              }

              volume_mount {
                name       = "world-config"
                mount_path = "/config"
                read_only  = true
              }

              volume_mount {
                name       = "world-backups"
                mount_path = "/backups"
              }
            }

            volume {
              name = "world-config"

              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.terraria_config.metadata[0].name
              }
            }

            volume {
              name = "world-backups"

              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.terraria_backups[0].metadata[0].name
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim.terraria_backups,
    kubernetes_persistent_volume_claim.terraria_config
  ]
}

resource "kubernetes_manifest" "terraria_alert_rules" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "terraria-alert-rules"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        release = helm_release.kube_prometheus_stack.name
      }
    }
    spec = {
      groups = [
        {
          name = "terraria.rules"
          rules = [
            {
              alert = "TerrariaServerDown"
              expr  = "probe_success{job='terraria-tcp-probe'} == 0"
              for   = "2m"
              labels = {
                severity = "critical"
              }
              annotations = {
                summary     = "Servidor Terraria indisponivel"
                description = "A sonda TCP do Terraria falhou por mais de 2 minutos."
              }
            },
            {
              alert = "TerrariaGameplayMetricsDown"
              expr  = "terraria_exporter_source_up == 0"
              for   = "10m"
              labels = {
                severity = "warning"
              }
              annotations = {
                summary     = "Exporter de gameplay sem dados"
                description = "A API de gameplay do Terraria nao respondeu por mais de 10 minutos."
              }
            }
          ]
        }
      ]
    }
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_manifest.terraria_tcp_probe,
    kubernetes_manifest.terraria_exporter_service_monitor
  ]
}

resource "kubernetes_manifest" "argocd_bootstrap_application" {
  count = var.argocd_enabled && var.argocd_app_enabled && local.argocd_repo_configured ? 1 : 0

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = var.argocd_app_name
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      source = {
        repoURL        = local.argocd_repo_url_trimmed
        targetRevision = var.argocd_app_target_revision
        path           = var.argocd_app_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "terrariadosbobo-gitops"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_repository
  ]
}



