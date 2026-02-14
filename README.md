# terrariadosbobo

Stack local de Terraria com Kubernetes + Terraform + observabilidade + GitOps.

## O que foi integrado

- Servidor Terraria em `terraria`
- PVC de mundo (`terraria-config`)
- Backup automático do mundo (`CronJob` + PVC `terraria-backups`)
- Prometheus + Grafana + Alertmanager (`kube-prometheus-stack`)
- Node exporter / kube-state-metrics
- Blackbox probe TCP do Terraria
- Exporter custom de gameplay (players/mundo/monstros/itens)
- Dashboards Grafana:
  - `Terraria K8s Overview`
  - `Terraria Gameplay Overview`
- Loki + Promtail para logs
- Argo CD (GitOps) via NodePort
- OAuth GitHub opcional no Grafana
- Alertas no Discord via Alertmanager (opcional)

## URLs locais

- Grafana: `http://localhost:30030`
- Prometheus: `http://localhost:30090`
- Argo CD: `http://localhost:30080`
- Terraria: `SEU_IP_LAN:30777`

## Configuracao

1. Copiar vars de exemplo:

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Editar `terraform/terraform.tfvars` e preencher no minimo:

- `world_file`
- `grafana_admin_password`

3. Para features opcionais:

- Discord alertas: `discord_webhook_url`
- OAuth GitHub: `grafana_github_oauth_enabled=true` + `grafana_github_client_id` + `grafana_github_client_secret`
- Gameplay API token (se TShock/API exigir): `terraria_api_token`

## Deploy

```powershell
./scripts/deploy.ps1
```

Depois liberar firewall (admin):

```powershell
./scripts/open-firewall.ps1
```

## Mundo

Enviar mapa:

```powershell
./scripts/upload-world.ps1 -WorldFile "C:/caminho/seu_mapa.wld"
```

Ou criar/garantir mundo por nome:

```powershell
./scripts/upload-world.ps1 -WorldName "test.wld"
```

## Validacao rapida

```powershell
kubectl get pods -A
kubectl get svc -n terraria
kubectl get svc -n monitoring
kubectl get svc -n argocd
```

Prometheus queries uteis:

```promql
terraria_exporter_source_up
terraria_players_online
terraria_monster_active
probe_success{job="terraria-tcp-probe"}
```

## Observacoes importantes

- Tudo esta focado em ambiente local.
- Se o cluster for recriado no Docker Desktop, reaplique com `terraform apply`.
- Se `terraria_exporter_source_up=0`, API de gameplay nao respondeu (URL/token/API do servidor).
- O Argo CD sobe, mas voce ainda precisa cadastrar o repo/app nele para fluxo GitOps completo.

## Destroy

```powershell
terraform -chdir=terraform destroy -auto-approve
```
