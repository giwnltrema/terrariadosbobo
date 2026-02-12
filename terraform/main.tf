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

resource "kubernetes_config_map" "prometheus" {
  metadata {
    name      = "prometheus-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "prometheus.yml" = <<-EOT
      global:
        scrape_interval: 15s

      scrape_configs:
        - job_name: prometheus
          static_configs:
            - targets: ['localhost:9090']
    EOT
  }
}

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "admin-user"     = var.grafana_admin_user
    "admin-password" = var.grafana_admin_password
  }

  type = "Opaque"
}

resource "kubernetes_deployment" "monitoring" {
  metadata {
    name      = "monitoring-stack"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app = "monitoring-stack"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "monitoring-stack"
      }
    }

    template {
      metadata {
        labels = {
          app = "monitoring-stack"
        }
      }

      spec {
        container {
          name              = "prometheus"
          image             = "prom/prometheus:latest"
          image_pull_policy = "IfNotPresent"

          args = [
            "--config.file=/etc/prometheus/prometheus.yml",
            "--storage.tsdb.path=/prometheus"
          ]

          port {
            container_port = 9090
            name           = "prometheus"
            protocol       = "TCP"
          }

          volume_mount {
            mount_path = "/etc/prometheus/prometheus.yml"
            name       = "prometheus-config"
            sub_path   = "prometheus.yml"
          }

          volume_mount {
            mount_path = "/prometheus"
            name       = "prometheus-data"
          }
        }

        container {
          name              = "grafana"
          image             = "grafana/grafana:latest"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 3000
            name           = "grafana"
            protocol       = "TCP"
          }

          env {
            name = "GF_SECURITY_ADMIN_USER"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana_admin.metadata[0].name
                key  = "admin-user"
              }
            }
          }

          env {
            name = "GF_SECURITY_ADMIN_PASSWORD"

            value_from {
              secret_key_ref {
                name = kubernetes_secret.grafana_admin.metadata[0].name
                key  = "admin-password"
              }
            }
          }

          volume_mount {
            mount_path = "/var/lib/grafana"
            name       = "grafana-data"
          }
        }

        volume {
          name = "prometheus-config"

          config_map {
            name = kubernetes_config_map.prometheus.metadata[0].name
          }
        }

        volume {
          name = "prometheus-data"
          empty_dir {}
        }

        volume {
          name = "grafana-data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "prometheus" {
  metadata {
    name      = "prometheus-service"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = {
      app = kubernetes_deployment.monitoring.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "prometheus"
      port        = 9090
      target_port = 9090
      node_port   = var.prometheus_node_port
      protocol    = "TCP"
    }

    type = "NodePort"
  }
}

resource "kubernetes_service" "grafana" {
  metadata {
    name      = "grafana-service"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    selector = {
      app = kubernetes_deployment.monitoring.spec[0].template[0].metadata[0].labels.app
    }

    port {
      name        = "grafana"
      port        = 3000
      target_port = 3000
      node_port   = var.grafana_node_port
      protocol    = "TCP"
    }

    type = "NodePort"
  }
}
