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
          image             = "beardedio/terraria:latest"
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

    type = "NodePort"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prom-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false

  values = [
    yamlencode({
      alertmanager = {
        enabled = false
      }
      grafana = {
        adminUser                = var.grafana_admin_user
        adminPassword            = var.grafana_admin_password
        defaultDashboardsEnabled = true
        service = {
          type     = "NodePort"
          nodePort = var.grafana_node_port
        }
        sidecar = {
          dashboards = {
            enabled = true
            label   = "grafana_dashboard"
          }
          datasources = {
            enabled = true
          }
        }
      }
      kubeStateMetrics = {
        enabled = true
      }
      nodeExporter = {
        enabled = true
      }
      prometheus = {
        service = {
          type     = "NodePort"
          nodePort = var.prometheus_node_port
        }
        prometheusSpec = {
          scrapeInterval                         = "15s"
          probeSelectorNilUsesHelmValues         = false
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues    = false
          ruleSelectorNilUsesHelmValues          = false
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring
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
            "title": "Terraria Pod CPU (cores)",
            "targets": [
              {
                "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\",container!=\\"\\"}[5m]))"
              }
            ],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "timeseries",
            "title": "Terraria Pod Memory (bytes)",
            "targets": [
              {
                "expr": "sum(container_memory_working_set_bytes{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\",container!=\\"\\"})"
              }
            ],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "title": "Terraria TCP Reachability",
            "targets": [
              {
                "expr": "probe_success{job=\\"terraria-tcp-probe\\"}"
              }
            ],
            "gridPos": {"h": 6, "w": 8, "x": 0, "y": 8}
          },
          {
            "id": 4,
            "type": "timeseries",
            "title": "Terraria Pod Restarts",
            "targets": [
              {
                "expr": "sum(kube_pod_container_status_restarts_total{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\"})"
              }
            ],
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
