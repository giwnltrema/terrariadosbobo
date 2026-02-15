output "terraria_connect_hint" {
  description = "Endereco para os jogadores conectarem"
  value       = var.terraria_connect_host != "" ? "Conecte em ${var.terraria_connect_host}:${var.terraria_node_port}" : "Use o IP LAN da sua maquina + porta ${var.terraria_node_port}"
}

output "grafana_url" {
  value = "http://localhost:${var.grafana_node_port}"
}

output "prometheus_url" {
  value = "http://localhost:${var.prometheus_node_port}"
}

output "argocd_url" {
  value = var.argocd_enabled ? "http://localhost:${var.argocd_node_port}" : "Argo CD desativado"
}

output "terraria_api_hint" {
  value = strcontains(lower(var.terraria_image), "tshock") ? "API de gameplay: ${var.terraria_api_url} (fallback parser .wld em /config/${var.world_file})" : "Imagem atual sem API TShock; exporter usa parser .wld em /config/${var.world_file}."
}

output "grafana_dashboard_hint" {
  value = "Abra os dashboards 'Terraria K8s Overview', 'Terraria Gameplay Overview' e 'Terraria Runtime Health'"
}

output "backup_hint" {
  value = var.terraria_backup_enabled ? "Backups em PVC terraria-backups via CronJob terraria-world-backup" : "Backups desativados"
}

output "world_upload_hint" {
  value = "Rode scripts/upload-world.ps1 (Windows) ou scripts/upload-world.sh (Linux/WSL)"
}

output "world_ui_url" {
  value = "http://localhost:30878"
}
