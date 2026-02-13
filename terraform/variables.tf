variable "kubeconfig_path" {
  description = "Caminho para o kubeconfig local"
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "Contexto do cluster local"
  type        = string
  default     = "docker-desktop"
}

variable "terraria_namespace" {
  description = "Namespace para o servidor Terraria"
  type        = string
  default     = "terraria"
}

variable "monitoring_namespace" {
  description = "Namespace para Prometheus + Grafana"
  type        = string
  default     = "monitoring"
}

variable "terraria_image" {
  description = "Imagem do servidor Terraria"
  type        = string
  default     = "ghcr.io/beardedio/terraria:tshock-latest"
}

variable "world_file" {
  description = "Nome do arquivo .wld que deve existir no volume /config"
  type        = string
  default     = "meu_mapa.wld"
}

variable "terraria_api_url" {
  description = "URL da API do Terraria/TShock para o exporter (vazio desativa coleta de gameplay)"
  type        = string
  default     = "http://terraria-service.terraria.svc.cluster.local:7878"
}

variable "terraria_api_token" {
  description = "Token da API do Terraria/TShock (se configurado no servidor)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "terraria_exporter_scrape_interval_seconds" {
  description = "Intervalo de coleta do exporter de gameplay"
  type        = number
  default     = 15
}

variable "terraria_node_port" {
  description = "NodePort para conexao dos jogadores"
  type        = number
  default     = 30777

  validation {
    condition     = var.terraria_node_port >= 30000 && var.terraria_node_port <= 32767
    error_message = "terraria_node_port deve estar entre 30000 e 32767."
  }
}

variable "prometheus_node_port" {
  description = "NodePort da UI do Prometheus"
  type        = number
  default     = 30090

  validation {
    condition     = var.prometheus_node_port >= 30000 && var.prometheus_node_port <= 32767
    error_message = "prometheus_node_port deve estar entre 30000 e 32767."
  }
}

variable "grafana_node_port" {
  description = "NodePort da UI do Grafana"
  type        = number
  default     = 30030

  validation {
    condition     = var.grafana_node_port >= 30000 && var.grafana_node_port <= 32767
    error_message = "grafana_node_port deve estar entre 30000 e 32767."
  }
}

variable "grafana_admin_user" {
  description = "Usuario admin do Grafana"
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Senha admin do Grafana"
  type        = string
  default     = "admin123"
  sensitive   = true
}
