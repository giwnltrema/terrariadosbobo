output "terraria_connect_hint" {
  description = "Endereco para os jogadores conectarem"
  value       = "Use o IP LAN da sua maquina + porta ${var.terraria_node_port}"
}

output "grafana_url" {
  value = "http://localhost:${var.grafana_node_port}"
}

output "prometheus_url" {
  value = "http://localhost:${var.prometheus_node_port}"
}

output "terraria_api_hint" {
  value = "API esperada para gameplay metrics: ${var.terraria_api_url}"
}

output "grafana_dashboard_hint" {
  value = "Abra os dashboards 'Terraria K8s Overview' e 'Terraria Gameplay Overview'"
}

output "world_upload_hint" {
  value = "Rode scripts/upload-world.ps1 -WorldFile C:/caminho/seu-mapa.wld"
}
