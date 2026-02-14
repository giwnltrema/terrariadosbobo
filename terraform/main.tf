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

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prom-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false
  timeout          = 1200

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
            enabled = true
            label   = "grafana_dashboard"
          }
          datasources = {
            enabled = true
          }
        }
        "grafana.ini" = {
          server = {
            root_url = "http://localhost:${var.grafana_node_port}"
          }
          auth = {
            disable_login_form = var.grafana_github_oauth_enabled
          }
          "auth.github" = {
            enabled               = var.grafana_github_oauth_enabled
            allow_sign_up         = true
            client_id             = var.grafana_github_client_id
            client_secret         = var.grafana_github_client_secret
            scopes                = "read:user,user:email"
            auth_url              = "https://github.com/login/oauth/authorize"
            token_url             = "https://github.com/login/oauth/access_token"
            api_url               = "https://api.github.com/user"
            allowed_organizations = join(" ", var.grafana_github_allowed_organizations)
          }
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
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "api-token" = var.terraria_api_token
  }

  type = "Opaque"
}

resource "kubernetes_config_map" "terraria_exporter_code" {
  metadata {
    name      = "terraria-exporter-code"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "exporter.py" = <<-EOT
      import json
      import os
      import time
      from typing import Any, Dict, List, Optional

      import requests
      from prometheus_client import Gauge, start_http_server

      API_BASE = os.getenv("TERRARIA_API_URL", "").rstrip("/")
      API_TOKEN = os.getenv("TERRARIA_API_TOKEN", "")
      SCRAPE_INTERVAL = int(os.getenv("SCRAPE_INTERVAL", "15"))
      EXPORTER_PORT = int(os.getenv("EXPORTER_PORT", "9150"))

      source_up = Gauge("terraria_exporter_source_up", "1 se API de gameplay respondeu")
      players_online = Gauge("terraria_players_online", "Quantidade de jogadores online")
      players_max = Gauge("terraria_players_max", "Capacidade maxima de jogadores")
      world_daytime = Gauge("terraria_world_daytime", "1 se dia, 0 se noite")
      world_blood_moon = Gauge("terraria_world_blood_moon", "1 se blood moon ativa")
      world_eclipse = Gauge("terraria_world_eclipse", "1 se eclipse ativa")
      world_hardmode = Gauge("terraria_world_hardmode", "1 se hardmode")
      world_time = Gauge("terraria_world_time", "Tempo do mundo")
      player_health = Gauge("terraria_player_health", "Vida do jogador", ["player"])
      player_mana = Gauge("terraria_player_mana", "Mana do jogador", ["player"])
      player_deaths = Gauge("terraria_player_deaths_total", "Mortes do jogador", ["player"])
      player_items = Gauge("terraria_player_item_count", "Quantidade de item por jogador", ["player", "item"])
      monster_count = Gauge("terraria_monster_active", "Monstros ativos por tipo", ["monster"])


      def _as_bool(value: Any) -> int:
          if isinstance(value, bool):
              return 1 if value else 0
          if isinstance(value, (int, float)):
              return 1 if value else 0
          if isinstance(value, str):
              lowered = value.strip().lower()
              return 1 if lowered in {"1", "true", "yes", "on", "day", "hardmode"} else 0
          return 0


      def _find_first(data: Any, keys: List[str]) -> Optional[Any]:
          if isinstance(data, dict):
              for key, value in data.items():
                  normalized = key.replace("_", "").replace("-", "").lower()
                  if normalized in keys:
                      return value
              for value in data.values():
                  found = _find_first(value, keys)
                  if found is not None:
                      return found
          if isinstance(data, list):
              for item in data:
                  found = _find_first(item, keys)
                  if found is not None:
                      return found
          return None


      def _request(paths: List[str]) -> Optional[Any]:
          if not API_BASE:
              return None

          params = {}
          if API_TOKEN:
              params["token"] = API_TOKEN

          for path in paths:
              url = f"{API_BASE}{path}"
              try:
                  response = requests.get(url, params=params, timeout=6)
                  if response.status_code != 200:
                      continue
                  if "application/json" in response.headers.get("content-type", ""):
                      return response.json()
                  try:
                      return json.loads(response.text)
                  except Exception:
                      continue
              except Exception:
                  continue
          return None


      def _extract_players(payload: Any) -> List[Dict[str, Any]]:
          if isinstance(payload, list):
              return [p for p in payload if isinstance(p, dict)]
          if isinstance(payload, dict):
              for key in ["players", "onlinePlayers", "playerList", "data"]:
                  value = payload.get(key)
                  if isinstance(value, list):
                      return [p for p in value if isinstance(p, dict)]
          return []


      def _extract_monsters(payload: Any) -> List[Dict[str, Any]]:
          if isinstance(payload, list):
              return [m for m in payload if isinstance(m, dict)]
          if isinstance(payload, dict):
              for key in ["monsters", "npcs", "activeMonsters", "activeNPCs", "data"]:
                  value = payload.get(key)
                  if isinstance(value, list):
                      return [m for m in value if isinstance(m, dict)]
          return []


      def scrape_once() -> None:
          source_up.set(0)
          players_online.set(0)
          players_max.set(0)
          world_daytime.set(0)
          world_blood_moon.set(0)
          world_eclipse.set(0)
          world_hardmode.set(0)
          world_time.set(0)
          player_health.clear()
          player_mana.clear()
          player_deaths.clear()
          player_items.clear()
          monster_count.clear()

          status = _request([
              "/status",
              "/v2/server/status",
              "/v3/server/status",
              "/v2/status",
          ])
          players = _request([
              "/players",
              "/v2/players/list",
              "/v3/players/list",
              "/v2/players",
          ])
          world = _request([
              "/world",
              "/v2/world/status",
              "/v3/world/status",
              "/v2/world",
          ])
          monsters = _request([
              "/monsters",
              "/v2/monsters/list",
              "/v3/monsters/list",
              "/v2/npcs/list",
          ])

          if status is None and players is None and world is None and monsters is None:
              return

          source_up.set(1)

          merged = {
              "status": status if status is not None else {},
              "players": players if players is not None else {},
              "world": world if world is not None else {},
              "monsters": monsters if monsters is not None else {},
          }

          online = _find_first(merged, ["onlineplayers", "playersonline", "playercount", "online"])
          maxp = _find_first(merged, ["maxplayers", "slots", "playerlimit"])

          if isinstance(online, (int, float)):
              players_online.set(float(online))
          if isinstance(maxp, (int, float)):
              players_max.set(float(maxp))

          daytime = _find_first(merged, ["daytime", "isday", "day"])
          blood = _find_first(merged, ["bloodmoon", "isbloodmoon"])
          eclipse = _find_first(merged, ["eclipse", "issolareclipse"])
          hardmode = _find_first(merged, ["hardmode", "ishardmode"])
          time_value = _find_first(merged, ["time", "worldtime", "timeofday"])

          if daytime is not None:
              world_daytime.set(_as_bool(daytime))
          if blood is not None:
              world_blood_moon.set(_as_bool(blood))
          if eclipse is not None:
              world_eclipse.set(_as_bool(eclipse))
          if hardmode is not None:
              world_hardmode.set(_as_bool(hardmode))
          if isinstance(time_value, (int, float)):
              world_time.set(float(time_value))

          parsed_players = _extract_players(players)
          if parsed_players:
              players_online.set(float(len(parsed_players)))

          for player in parsed_players:
              name = str(player.get("name") or player.get("playerName") or player.get("username") or "unknown")

              life = player.get("health", player.get("life", player.get("hp", 0)))
              mana = player.get("mana", player.get("mp", 0))
              deaths = player.get("deaths", player.get("deathCount", 0))

              if isinstance(life, (int, float)):
                  player_health.labels(player=name).set(float(life))
              if isinstance(mana, (int, float)):
                  player_mana.labels(player=name).set(float(mana))
              if isinstance(deaths, (int, float)):
                  player_deaths.labels(player=name).set(float(deaths))

              inventory = player.get("inventory", [])
              if isinstance(inventory, list):
                  for item in inventory:
                      if not isinstance(item, dict):
                          continue
                      item_name = str(item.get("name") or item.get("itemName") or "unknown")
                      amount = item.get("stack", item.get("amount", 0))
                      if isinstance(amount, (int, float)):
                          player_items.labels(player=name, item=item_name).set(float(amount))

          parsed_monsters = _extract_monsters(monsters)
          bucket: Dict[str, int] = {}
          for monster in parsed_monsters:
              mname = str(monster.get("name") or monster.get("npcName") or monster.get("type") or "unknown")
              bucket[mname] = bucket.get(mname, 0) + 1

          for mname, count in bucket.items():
              monster_count.labels(monster=mname).set(float(count))


      def main() -> None:
          start_http_server(EXPORTER_PORT)
          while True:
              try:
                  scrape_once()
              except Exception:
                  source_up.set(0)
              time.sleep(SCRAPE_INTERVAL)


      if __name__ == "__main__":
          main()
    EOT
  }
}

resource "kubernetes_deployment" "terraria_exporter" {
  metadata {
    name      = "terraria-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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
        container {
          name              = "terraria-exporter"
          image             = "python:3.12-slim"
          image_pull_policy = "IfNotPresent"

          command = ["sh", "-c"]
          args = [
            "pip install --no-cache-dir prometheus-client requests >/tmp/pip.log 2>&1 && python /app/exporter.py"
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
            name  = "SCRAPE_INTERVAL"
            value = tostring(var.terraria_exporter_scrape_interval_seconds)
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
        }

        volume {
          name = "exporter-code"
          config_map {
            name = kubernetes_config_map.terraria_exporter_code.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "kubernetes_service" "terraria_exporter" {
  metadata {
    name      = "terraria-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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
        matchNames = [kubernetes_namespace.monitoring.metadata[0].name]
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
            "title": "Terraria Pod CPU (cores)",
            "targets": [{"expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\",container!=\\"\\"}[5m]))"}],
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "timeseries",
            "title": "Terraria Pod Memory (bytes)",
            "targets": [{"expr": "sum(container_memory_working_set_bytes{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\",container!=\\"\\"})"}],
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "title": "Terraria TCP Reachability",
            "targets": [{"expr": "probe_success{job=\\"terraria-tcp-probe\\"}"}],
            "gridPos": {"h": 6, "w": 8, "x": 0, "y": 8}
          },
          {
            "id": 4,
            "type": "timeseries",
            "title": "Terraria Pod Restarts",
            "targets": [{"expr": "sum(kube_pod_container_status_restarts_total{namespace=\\"terraria\\",pod=~\\"terraria-server-.*\\"})"}],
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
            "title": "API Source Up",
            "targets": [{"expr": "terraria_exporter_source_up"}],
            "gridPos": {"h": 4, "w": 4, "x": 0, "y": 0}
          },
          {
            "id": 2,
            "type": "stat",
            "title": "Players Online",
            "targets": [{"expr": "terraria_players_online"}],
            "gridPos": {"h": 4, "w": 4, "x": 4, "y": 0}
          },
          {
            "id": 3,
            "type": "stat",
            "title": "Players Max",
            "targets": [{"expr": "terraria_players_max"}],
            "gridPos": {"h": 4, "w": 4, "x": 8, "y": 0}
          },
          {
            "id": 4,
            "type": "stat",
            "title": "Hardmode",
            "targets": [{"expr": "terraria_world_hardmode"}],
            "gridPos": {"h": 4, "w": 4, "x": 12, "y": 0}
          },
          {
            "id": 5,
            "type": "stat",
            "title": "Blood Moon",
            "targets": [{"expr": "terraria_world_blood_moon"}],
            "gridPos": {"h": 4, "w": 4, "x": 16, "y": 0}
          },
          {
            "id": 6,
            "type": "stat",
            "title": "Eclipse",
            "targets": [{"expr": "terraria_world_eclipse"}],
            "gridPos": {"h": 4, "w": 4, "x": 20, "y": 0}
          },
          {
            "id": 7,
            "type": "timeseries",
            "title": "Players Online Over Time",
            "targets": [{"expr": "terraria_players_online"}],
            "gridPos": {"h": 8, "w": 8, "x": 0, "y": 4}
          },
          {
            "id": 8,
            "type": "timeseries",
            "title": "World Time",
            "targets": [{"expr": "terraria_world_time"}],
            "gridPos": {"h": 8, "w": 8, "x": 8, "y": 4}
          },
          {
            "id": 9,
            "type": "timeseries",
            "title": "Player Health",
            "targets": [{"expr": "terraria_player_health"}],
            "gridPos": {"h": 8, "w": 8, "x": 16, "y": 4}
          },
          {
            "id": 10,
            "type": "timeseries",
            "title": "Player Mana",
            "targets": [{"expr": "terraria_player_mana"}],
            "gridPos": {"h": 8, "w": 8, "x": 0, "y": 12}
          },
          {
            "id": 11,
            "type": "timeseries",
            "title": "Player Deaths Total",
            "targets": [{"expr": "terraria_player_deaths_total"}],
            "gridPos": {"h": 8, "w": 8, "x": 8, "y": 12}
          },
          {
            "id": 12,
            "type": "barchart",
            "title": "Monsters Active by Type",
            "targets": [{"expr": "topk(15, terraria_monster_active)"}],
            "gridPos": {"h": 8, "w": 8, "x": 16, "y": 12}
          },
          {
            "id": 13,
            "type": "table",
            "title": "Player Items",
            "targets": [{"expr": "topk(100, terraria_player_item_count)"}],
            "gridPos": {"h": 8, "w": 24, "x": 0, "y": 20}
          }
        ],
        "schemaVersion": 39,
        "style": "dark",
        "tags": ["terraria", "gameplay", "tshock"],
        "templating": {"list": []},
        "time": {"from": "now-6h", "to": "now"},
        "title": "Terraria Gameplay Overview",
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




