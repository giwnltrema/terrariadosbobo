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

variable "argocd_namespace" {
  description = "Namespace do Argo CD"
  type        = string
  default     = "argocd"
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

variable "terraria_world_parse_interval_seconds" {
  description = "Intervalo de parsing do arquivo .wld no exporter"
  type        = number
  default     = 30
}

variable "terraria_chest_item_series_limit" {
  description = "Limite de series por chest/item expostas no Prometheus"
  type        = number
  default     = 500
}
variable "monitoring_storage_class" {
  description = "StorageClass para persistencia local"
  type        = string
  default     = "hostpath"
}

variable "prometheus_persistence_size" {
  description = "Tamanho do volume persistente do Prometheus"
  type        = string
  default     = "20Gi"
}

variable "grafana_persistence_size" {
  description = "Tamanho do volume persistente do Grafana"
  type        = string
  default     = "5Gi"
}

variable "loki_enabled" {
  description = "Habilita stack Loki/Promtail"
  type        = bool
  default     = true
}

variable "loki_persistence_size" {
  description = "Tamanho do volume persistente do Loki"
  type        = string
  default     = "10Gi"
}

variable "argocd_enabled" {
  description = "Habilita Argo CD"
  type        = bool
  default     = true
}

variable "argocd_node_port" {
  description = "NodePort HTTP do Argo CD"
  type        = number
  default     = 30080

  validation {
    condition     = var.argocd_node_port >= 30000 && var.argocd_node_port <= 32767
    error_message = "argocd_node_port deve estar entre 30000 e 32767."
  }
}

variable "discord_webhook_url" {
  description = "Webhook do Discord para alertas do Alertmanager (vazio desativa envio)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_github_oauth_enabled" {
  description = "Habilita login GitHub no Grafana"
  type        = bool
  default     = false
}

variable "grafana_github_client_id" {
  description = "Client ID OAuth do GitHub para Grafana"
  type        = string
  default     = ""
}

variable "grafana_github_client_secret" {
  description = "Client Secret OAuth do GitHub para Grafana"
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_github_allowed_organizations" {
  description = "Orgs do GitHub permitidas no login do Grafana (array vazio libera todas)"
  type        = list(string)
  default     = []
}

variable "terraria_backup_enabled" {
  description = "Habilita job de backup do mundo para PVC local"
  type        = bool
  default     = true
}

variable "terraria_backup_schedule" {
  description = "Cron schedule do backup do mundo"
  type        = string
  default     = "0 */6 * * *"
}

variable "terraria_backup_retention_count" {
  description = "Quantidade maxima de arquivos de backup mantidos"
  type        = number
  default     = 20
}

variable "terraria_backup_pvc_size" {
  description = "Tamanho do PVC de backup local do mundo"
  type        = string
  default     = "10Gi"
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

variable "terraria_connect_host" {
  description = "Host/IP exibido no output de conexao dos jogadores (vazio = hint generico)"
  type        = string
  default     = ""
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


variable "argocd_app_enabled" {
  description = "Habilita criacao de Application bootstrap no Argo CD"
  type        = bool
  default     = true
}

variable "argocd_app_name" {
  description = "Nome da Application bootstrap no Argo CD"
  type        = string
  default     = "terrariadosbobo-bootstrap"
}

variable "argocd_app_repo_url" {
  description = "Repositorio Git para Application bootstrap do Argo CD (vazio = scripts/deploy.* tentam detectar remote.origin.url)"
  type        = string
  default     = ""
}

variable "argocd_repo_username" {
  description = "Usuario para autenticar repositorio Git no Argo CD (opcional)"
  type        = string
  default     = ""
}

variable "argocd_repo_password" {
  description = "Senha/token para autenticar repositorio Git no Argo CD (opcional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_repo_ssh_private_key" {
  description = "Chave SSH privada para autenticar repositorio Git no Argo CD (opcional)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_app_target_revision" {
  description = "Branch/tag/commit para Argo CD Application"
  type        = string
  default     = "main"
}

variable "argocd_app_path" {
  description = "Path do app no repositorio para Argo CD"
  type        = string
  default     = "argocd/apps/bootstrap"
}

variable "argocd_world_ui_app_enabled" {
  description = "Cria Application dedicada do Argo CD para a world-ui (normalmente desnecessario quando bootstrap app-of-apps esta habilitado)"
  type        = bool
  default     = false
}

variable "argocd_world_ui_app_name" {
  description = "Nome da Application Argo CD para world-ui"
  type        = string
  default     = "terrariadosbobo-world-ui"
}

variable "argocd_world_ui_app_path" {
  description = "Path GitOps da world-ui no repositorio"
  type        = string
  default     = "argocd/apps/world-ui"
}

