# terrariadosbobo

Servidor local de Terraria em Kubernetes com Terraform, Prometheus e Grafana, incluindo dashboard de gameplay.

## O que este projeto sobe

- Servidor Terraria (`terraria` namespace)
- PVC para mundo/config (`terraria-config`)
- Service NodePort para jogo (`30777` por padrao)
- `kube-prometheus-stack` (`monitoring` namespace)
- `blackbox-exporter` (saude TCP do server)
- `terraria-exporter` custom (metricas de gameplay)
- Dashboards Grafana:
  - `Terraria K8s Overview`
  - `Terraria Gameplay Overview`

## Stack de gameplay metrics

O exporter de gameplay consulta API do servidor (TShock/API compatível) e publica no Prometheus:

- `terraria_players_online`
- `terraria_players_max`
- `terraria_world_daytime`
- `terraria_world_blood_moon`
- `terraria_world_eclipse`
- `terraria_world_hardmode`
- `terraria_world_time`
- `terraria_player_health{player=...}`
- `terraria_player_mana{player=...}`
- `terraria_player_deaths_total{player=...}`
- `terraria_player_item_count{player=...,item=...}`
- `terraria_monster_active{monster=...}`
- `terraria_exporter_source_up` (1 quando API responde)

## Pre-requisitos

1. Docker Desktop com Kubernetes ativo
2. `kubectl`, `terraform` e `helm` instalados
3. Contexto `docker-desktop`
4. PowerShell para scripts (`scripts/*.ps1`)

## Configuracao

Copie e edite:

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
notepad terraform/terraform.tfvars
```

Campos importantes:

- `terraria_image` (default: `ghcr.io/beardedio/terraria:tshock-latest`)
- `world_file`
- `terraria_api_url` (default interno: `http://terraria-service.terraria.svc.cluster.local:7878`)
- `terraria_api_token` (se sua API exigir token)
- `grafana_admin_user` / `grafana_admin_password`

## Deploy

```powershell
./scripts/deploy.ps1
```

O script:
- valida cluster
- bootstrapa CRDs de monitoramento na primeira vez
- aplica Terraform
- garante mundo no PVC (cria automatico se faltar)

## Upload de mapa

Enviar arquivo próprio:

```powershell
./scripts/upload-world.ps1 -WorldFile "C:/caminho/seu_mapa.wld"
```

Ou apenas garantir/criar por nome:

```powershell
./scripts/upload-world.ps1 -WorldName "test.wld"
```

## Acesso

- Terraria: `SEU_IP_LAN:30777`
- Grafana: `http://localhost:30030`
- Prometheus: `http://localhost:30090`

Abra firewall (Admin):

```powershell
./scripts/open-firewall.ps1
```

## Validacao rapida

```powershell
kubectl get pods -n terraria
kubectl get pods -n monitoring
kubectl get svc -n terraria
kubectl get svc -n monitoring
```

No Prometheus, teste:

```promql
terraria_exporter_source_up
terraria_players_online
terraria_monster_active
```

Se `terraria_exporter_source_up = 0`, a API de gameplay nao respondeu (URL/token/servidor).

## Dashboards

No Grafana, confira:

1. `Terraria K8s Overview`
2. `Terraria Gameplay Overview`

Se estiver vazio logo após subir, aguarde 1-3 minutos para scrape e recarregue.

## Destroy

```powershell
terraform -chdir=terraform destroy -auto-approve
```
