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

output "world_upload_hint" {
  value = "Rode scripts/upload-world.ps1 -WorldFile C:/caminho/seu-mapa.wld"
}
