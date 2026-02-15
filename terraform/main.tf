resource "kubernetes_namespace" "terraria" {
  metadata {
    name = var.terraria_namespace
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
  }
}

resource "kubernetes_persistent_volume_claim" "terraria_config" {
  metadata {
    name      = "terraria-config"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "terraria" {
  wait_for_rollout = false
  metadata {
    name      = "terraria-server"
    namespace = kubernetes_namespace.terraria.metadata[0].name
    labels = {
      app = "terraria-server"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "terraria-server"
      }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          app = "terraria-server"
        }
      }

      spec {
        container {
          name              = "terraria"
          image             = var.terraria_image
          image_pull_policy = "IfNotPresent"

          stdin = true
          tty   = true

          env {
            name  = "world"
            value = var.world_file
          }

          env {
            name  = "worldpath"
            value = "/config"
          }

          port {
            container_port = 7777
            name           = "terraria"
            protocol       = "TCP"
          }

          port {
            container_port = 7878
            name           = "terraria-api"
            protocol       = "TCP"
          }

          volume_mount {
            mount_path = "/config"
            name       = "terraria-config"
          }
        }

        volume {
          name = "terraria-config"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.terraria_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "terraria" {
  metadata {
    name      = "terraria-service"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  spec {
    selector = {
      app = kubernetes_deployment.terraria.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "terraria"
      port        = 7777
      target_port = 7777
      node_port   = var.terraria_node_port
      protocol    = "TCP"
    }

    port {
      name        = "terraria-api"
      port        = 7878
      target_port = 7878
      protocol    = "TCP"
    }

    type = "NodePort"
  }
}

locals {
  grafana_github_allowed_orgs_trimmed = [
    for org in var.grafana_github_allowed_organizations : trimspace(org)
    if trimspace(org) != ""
  ]

  grafana_github_oauth_scopes = "read:user,user:email,read:org"

  grafana_github_auth = merge(
    {
      enabled                    = var.grafana_github_oauth_enabled
      allow_sign_up              = true
      role_attribute_path   = "'Admin'"
      role_attribute_strict = false
      client_id                  = var.grafana_github_client_id
      client_secret              = var.grafana_github_client_secret
      scopes                     = local.grafana_github_oauth_scopes
      auth_url                   = "https://github.com/login/oauth/authorize"
      token_url                  = "https://github.com/login/oauth/access_token"
      api_url                    = "https://api.github.com/user"
    },
    length(local.grafana_github_allowed_orgs_trimmed) > 0 ? {
      allowed_organizations = join(" ", local.grafana_github_allowed_orgs_trimmed)
    } : {}
  )
}
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prom-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 1200
  wait             = false

  values = [
    yamlencode({
      alertmanager = {
        enabled = true
        alertmanagerSpec = {
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.monitoring_storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "5Gi"
                  }
                }
              }
            }
          }
        }
        config = {
          route = {
            receiver        = var.discord_webhook_url != "" ? "discord" : "null"
            group_by        = ["alertname"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "4h"
          }
          receivers = [
            {
              name = "discord"
              webhook_configs = [
                {
                  url           = var.discord_webhook_url != "" ? var.discord_webhook_url : "http://127.0.0.1:65535"
                  send_resolved = true
                }
              ]
            },
            {
              name            = "null"
              webhook_configs = []
            }
          ]
        }
      }
      grafana = {
        assertNoLeakedSecrets      = false
        adminUser                = var.grafana_admin_user
        adminPassword            = var.grafana_admin_password
        defaultDashboardsEnabled = true
        initChownData = {
          enabled = false
        }
        serviceMonitor = {
          enabled       = true
          interval      = "15s"
          scrapeTimeout = "10s"
        }
        service = {
          type     = "NodePort"
          nodePort = var.grafana_node_port
        }
        persistence = {
          enabled          = true
          storageClassName = var.monitoring_storage_class
          accessModes      = ["ReadWriteOnce"]
          size             = var.grafana_persistence_size
        }
        sidecar = {
          dashboards = {
            enabled         = true
            label           = "grafana_dashboard"
            searchNamespace = var.monitoring_namespace
          }
          datasources = {
            enabled                  = true
            label                    = "grafana_datasource"
            searchNamespace          = var.monitoring_namespace
            defaultDatasourceEnabled = false
          }
        }
        "grafana.ini" = {
          server = {
            root_url = "http://localhost:${var.grafana_node_port}"
          }
          auth = {
            disable_login_form = false
          }
          users = {
            auto_assign_org_role = "Admin"
          }
          "auth.github" = local.grafana_github_auth
        }
      }
      kubeStateMetrics = {
        enabled = true
      }
      nodeExporter = {
        enabled = true
      }
      "prometheus-node-exporter" = {
        hostRootFsMount = {
          enabled = false
        }
      }
      prometheus = {
        service = {
          type     = "NodePort"
          nodePort = var.prometheus_node_port
        }
        prometheusSpec = {
          scrapeInterval                           = "15s"
          probeSelectorNilUsesHelmValues          = false
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.monitoring_storage_class
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = var.prometheus_persistence_size
                  }
                }
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring
  ]
}

resource "kubernetes_secret" "terraria_api" {
  metadata {
    name      = "terraria-api-credentials"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  data = {
    "api-token" = var.terraria_api_token
  }

  type = "Opaque"
}

resource "kubernetes_service_account" "terraria_exporter" {
  metadata {
    name      = "terraria-exporter"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }
}

resource "kubernetes_role" "terraria_exporter_logs" {
  metadata {
    name      = "terraria-exporter-logs-reader"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding" "terraria_exporter_logs" {
  metadata {
    name      = "terraria-exporter-logs-reader"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.terraria_exporter_logs.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.terraria_exporter.metadata[0].name
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }
}

resource "kubernetes_config_map" "terraria_exporter_code" {
  metadata {
    name      = "terraria-exporter-code"
    namespace = kubernetes_namespace.terraria.metadata[0].name
  }

  data = {
    "exporter.py" = file("${path.module}/../exporter/exporter.py")
  }
}

resource "kubernetes_deployment" "terraria_exporter" {
  metadata {
    name      = "terraria-exporter"
    namespace = kubernetes_namespace.terraria.metadata[0].name
    labels = {
      app = "terraria-exporter"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "terraria-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "terraria-exporter"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.terraria_exporter.metadata[0].name

        container {
          name              = "terraria-exporter"
          image             = "python:3.12-slim"
          image_pull_policy = "IfNotPresent"

          command = ["sh", "-c"]
          args = [
            "pip install --no-cache-dir prometheus-client requests lihzahrd==3.1.0 >/tmp/pip.log 2>&1 && python /app/exporter.py"
          ]

          env {
            name  = "TERRARIA_API_URL"
            value = var.terraria_api_url
          }

          env {
            name = "TERRARIA_API_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.terraria_api.metadata[0].name
                key  = "api-token"
              }
            }
          }

          env {
            name  = "WORLD_FILE_PATH"
            value = "/config/${var.world_file}"
          }

          env {
            name  = "SERVER_CONFIG_PATH"
            value = "/config/serverconfig.txt"
          }

          env {
            name  = "WORLD_PARSE_INTERVAL"
            value = tostring(var.terraria_world_parse_interval_seconds)
          }

          env {
            name  = "CHEST_ITEM_SERIES_LIMIT"
            value = tostring(var.terraria_chest_item_series_limit)
          }

          env {
            name  = "SCRAPE_INTERVAL"
            value = tostring(var.terraria_exporter_scrape_interval_seconds)
          }

          env {
            name  = "K8S_NAMESPACE"
            value = kubernetes_namespace.terraria.metadata[0].name
          }

          env {
            name  = "K8S_TERRARIA_LABEL_SELECTOR"
            value = "app=terraria-server"
          }

          env {
            name  = "K8S_TERRARIA_CONTAINER"
            value = "terraria"
          }

          env {
            name  = "ENABLE_LOG_PLAYER_TRACKER"
            value = "true"
          }

          env {
            name  = "EXPORTER_PORT"
            value = "9150"
          }

          port {
            container_port = 9150
            name           = "metrics"
            protocol       = "TCP"
          }

          volume_mount {
            name       = "exporter-code"
            mount_path = "/app/exporter.py"
            sub_path   = "exporter.py"
          }

          volume_mount {
            name       = "terraria-config"
            mount_path = "/config"
            read_only  = true
          }
        }

        volume {
          name = "exporter-code"
          config_map {
            name = kubernetes_config_map.terraria_exporter_code.metadata[0].name
          }
        }

        volume {
          name = "terraria-config"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.terraria_config.metadata[0].name
            read_only  = true
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_role_binding.terraria_exporter_logs
  ]
}

resource "kubernetes_service" "terraria_exporter" {
  metadata {
    name      = "terraria-exporter"
    namespace = kubernetes_namespace.terraria.metadata[0].name
    labels = {
      app = "terraria-exporter"
    }
  }

  spec {
    selector = {
      app = kubernetes_deployment.terraria_exporter.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "metrics"
      port        = 9150
      target_port = 9150
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_manifest" "terraria_exporter_service_monitor" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "terraria-exporter"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        release = helm_release.kube_prometheus_stack.name
      }
    }
    spec = {
      namespaceSelector = {
        matchNames = [kubernetes_namespace.terraria.metadata[0].name]
      }
      selector = {
        matchLabels = {
          app = kubernetes_service.terraria_exporter.metadata[0].labels.app
        }
      }
      endpoints = [
        {
          port     = "metrics"
          path     = "/metrics"
          interval = "30s"
        }
      ]
    }
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_service.terraria_exporter
  ]
}

resource "kubernetes_config_map" "terraria_grafana_dashboards" {
  metadata {
    name      = "terraria-dashboards"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "terraria-k8s-overview.json" = <<-EOT
      {
        "annotations": {"list": []},
        "editable": true,
        "panels": [
          {
            "id": 1,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Terraria CPU Requests (cores)",
            "targets": [{"expr": "sum(kube_pod_container_resource_requests{namespace=\"terraria\",pod=~\"terraria-server-.*\",resource=\"cpu\",unit=\"core\"}) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Terraria Memory Requests (bytes)",
            "targets": [{"expr": "sum(kube_pod_container_resource_requests{namespace=\"terraria\",pod=~\"terraria-server-.*\",resource=\"memory\",unit=\"byte\"}) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Terraria TCP Reachability",
            "targets": [{"expr": "probe_success{job=\"terraria-tcp-probe\"}"}],
            "gridPos": {"h": 6, "w": 8, "x": 0, "y": 8}
          },
          {
            "id": 4,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Terraria Pod Restarts",
            "targets": [{"expr": "sum(kube_pod_container_status_restarts_total{namespace=\"terraria\",pod=~\"terraria-server-.*\"}) or vector(0)"}],
            "gridPos": {"h": 6, "w": 16, "x": 8, "y": 8}
          }
        ],
        "schemaVersion": 39,
        "style": "dark",
        "tags": ["terraria", "kubernetes"],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "title": "Terraria K8s Overview",
        "version": 1
      }
    EOT

    "terraria-gameplay-overview.json" = <<-EOT
      {
        "annotations": {"list": []},
        "editable": true,
        "panels": [
          {
            "id": 1,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "API Source Up",
            "targets": [{"expr": "max(terraria_exporter_source_up)"}],
            "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Parser Up",
            "targets": [{"expr": "max(terraria_world_parser_up)"}],
            "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Players Online",
            "targets": [{"expr": "max(terraria_players_online)"}],
            "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0}
          },
          {
            "id": 4,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Players Max",
            "targets": [{"expr": "max(terraria_players_max)"}],
            "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0}
          },
          {
            "id": 5,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Hardmode",
            "targets": [{"expr": "max(terraria_world_hardmode)"}],
            "gridPos": {"h": 4, "w": 8, "x": 0, "y": 4}
          },
          {
            "id": 6,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Blood Moon",
            "targets": [{"expr": "max(terraria_world_blood_moon)"}],
            "gridPos": {"h": 4, "w": 8, "x": 8, "y": 4}
          },
          {
            "id": 7,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Eclipse",
            "targets": [{"expr": "max(terraria_world_eclipse)"}],
            "gridPos": {"h": 4, "w": 8, "x": 16, "y": 4}
          },
          {
            "id": 8,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Players Online Over Time",
            "targets": [{"expr": "max(terraria_players_online)", "legendFormat": "Players"}],
            "gridPos": {"h": 8, "w": 8, "x": 0, "y": 8}
          },
          {
            "id": 9,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Time (Runtime)",
            "targets": [{"expr": "max(terraria_world_time_runtime) or vector(0)", "legendFormat": "World Time"}],
            "gridPos": {"h": 8, "w": 8, "x": 8, "y": 8}
          },
          {
            "id": 10,
            "type": "bargauge",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Structures (Snapshot)",
            "targets": [
              {"expr": "max(terraria_world_chests_total)", "legendFormat": "Chests"},
              {"expr": "max(terraria_world_houses_total)", "legendFormat": "Houses"},
              {"expr": "max(terraria_world_housed_npcs_total)", "legendFormat": "Housed NPCs"}
            ],
            "gridPos": {"h": 8, "w": 8, "x": 16, "y": 8}
          },
          {
            "id": 11,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Player Health",
            "targets": [{"expr": "max by (player) (terraria_player_health) or vector(0)"}],
            "gridPos": {"h": 8, "w": 8, "x": 0, "y": 16}
          },
          {
            "id": 12,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Player Mana",
            "targets": [{"expr": "max by (player) (terraria_player_mana) or vector(0)"}],
            "gridPos": {"h": 8, "w": 8, "x": 8, "y": 16}
          },
          {
            "id": 13,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Player Deaths Total",
            "targets": [{"expr": "max by (player) (terraria_player_deaths_total) or vector(0)"}],
            "gridPos": {"h": 8, "w": 8, "x": 16, "y": 16}
          },
          {
            "id": 14,
            "type": "barchart",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Monsters Active by Type",
            "targets": [{"expr": "topk(20, sum by (monster) (terraria_monster_active)) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24}
          },
          {
            "id": 15,
            "type": "table",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Player Items",
            "targets": [{"expr": "topk(100, sum by (player, item) (terraria_player_item_count)) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24}
          },
          {
            "id": 16,
            "type": "table",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Chest Items (Top 100)",
            "targets": [{"expr": "topk(100, sum by (chest, item) (terraria_chest_item_count)) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 32}
          },
          {
            "id": 17,
            "type": "barchart",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Chest Items by Type (Top 30)",
            "targets": [{"expr": "topk(30, sum by (item) (terraria_chest_item_count_by_item)) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 32}
          },
          {
            "id": 18,
            "type": "table",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Housed NPCs",
            "targets": [{"expr": "sum by (npc) (terraria_world_housed_npc)"}],
            "gridPos": {"h": 8, "w": 24, "x": 0, "y": 40}
          }
        ],
        "schemaVersion": 39,
        "style": "dark",
        "tags": ["terraria", "gameplay", "tshock"],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "title": "Terraria Gameplay Overview",
        "version": 3
      }
    EOT

    "terraria-runtime-health.json" = <<-EOT
      {
        "annotations": {"list": []},
        "editable": true,
        "panels": [
          {
            "id": 1,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "API Source Up",
            "targets": [{"expr": "max(terraria_exporter_source_up) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Runtime Source Up",
            "targets": [{"expr": "max(terraria_world_runtime_up) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Parser Up",
            "targets": [{"expr": "max(terraria_world_parser_up) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0}
          },
          {
            "id": 4,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Log Tracker Up",
            "targets": [{"expr": "max(terraria_log_tracker_up) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0}
          },
          {
            "id": 5,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Players Online by Source",
            "targets": [
              {"expr": "max(terraria_players_online) or vector(0)", "legendFormat": "Effective"},
              {"expr": "max(terraria_players_online_api) or vector(0)", "legendFormat": "API"},
              {"expr": "max(terraria_players_online_log) or vector(0)", "legendFormat": "Log fallback"}
            ],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4}
          },
          {
            "id": 6,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Runtime Flags",
            "targets": [
              {"expr": "max(terraria_world_daytime) or vector(0)", "legendFormat": "Daytime"},
              {"expr": "max(terraria_world_blood_moon) or vector(0)", "legendFormat": "Blood Moon"},
              {"expr": "max(terraria_world_eclipse) or vector(0)", "legendFormat": "Eclipse"},
              {"expr": "max(terraria_world_hardmode) or vector(0)", "legendFormat": "Hardmode"}
            ],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4}
          },
          {
            "id": 7,
            "type": "timeseries",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Snapshot Age (seconds)",
            "targets": [{"expr": "max(terraria_world_snapshot_age_seconds) or vector(0)"}],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 12}
          },
          {
            "id": 8,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "World Snapshot mtime (epoch)",
            "targets": [{"expr": "max(terraria_world_snapshot_mtime_seconds) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 12, "y": 12}
          },
          {
            "id": 9,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Probe TCP Reachability",
            "targets": [{"expr": "max(probe_success{job=\"terraria-tcp-probe\"}) or vector(0)"}],
            "gridPos": {"h": 4, "w": 6, "x": 18, "y": 12}
          },
          {
            "id": 10,
            "type": "stat",
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "title": "Fallback In Use",
            "targets": [{"expr": "((max(terraria_players_online_log) > 0) * 1) or vector(0)"}],
            "gridPos": {"h": 4, "w": 12, "x": 12, "y": 16}
          }
        ],
        "schemaVersion": 39,
        "style": "dark",
        "tags": ["terraria", "runtime", "health", "debug"],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "title": "Terraria Runtime Health",
        "version": 1
      }
    EOT
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_config_map" "blackbox_config" {
  metadata {
    name      = "terraria-blackbox-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "blackbox.yml" = <<-EOT
      modules:
        tcp_connect:
          prober: tcp
          timeout: 5s
    EOT
  }
}

resource "kubernetes_deployment" "blackbox_exporter" {
  metadata {
    name      = "terraria-blackbox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "terraria-blackbox-exporter"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "terraria-blackbox-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "terraria-blackbox-exporter"
        }
      }

      spec {
        container {
          name              = "blackbox-exporter"
          image             = "prom/blackbox-exporter:v0.25.0"
          image_pull_policy = "IfNotPresent"
          args              = ["--config.file=/etc/blackbox/blackbox.yml"]

          port {
            container_port = 9115
            name           = "http"
            protocol       = "TCP"
          }

          volume_mount {
            mount_path = "/etc/blackbox/blackbox.yml"
            name       = "blackbox-config"
            sub_path   = "blackbox.yml"
          }
        }

        volume {
          name = "blackbox-config"

          config_map {
            name = kubernetes_config_map.blackbox_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "blackbox_exporter" {
  metadata {
    name      = "terraria-blackbox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "terraria-blackbox-exporter"
    }
  }

  spec {
    selector = {
      app = kubernetes_deployment.blackbox_exporter.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "http"
      port        = 9115
      target_port = 9115
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_manifest" "terraria_tcp_probe" {
  manifest = {
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "Probe"
    metadata = {
      name      = "terraria-tcp-probe"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        release = helm_release.kube_prometheus_stack.name
      }
    }
    spec = {
      jobName  = "terraria-tcp-probe"
      interval = "30s"
      module   = "tcp_connect"
      prober = {
        url = "${kubernetes_service.blackbox_exporter.metadata[0].name}.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local:9115"
      }
      targets = {
        staticConfig = {
          static = [
            "${kubernetes_service.terraria.metadata[0].name}.${kubernetes_namespace.terraria.metadata[0].name}.svc.cluster.local:7777"
          ]
        }
      }
    }
  }

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_service.blackbox_exporter,
    kubernetes_service.terraria
  ]
}

