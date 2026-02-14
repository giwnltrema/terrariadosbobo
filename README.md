# terrariadosbobo

Stack local de Terraria com Kubernetes + Terraform + observabilidade + GitOps.

## O que este projeto sobe

- Servidor Terraria (`terraria-server`) com PVC de mundo (`terraria-config`)
- Upload/criacao automatica de mundo
- Prometheus + Grafana + Alertmanager (`kube-prometheus-stack`)
- Node exporter + kube-state-metrics
- Blackbox probe TCP do servidor
- Exporter custom de gameplay
  - Fonte 1: API TShock/REST (quando disponivel)
  - Fonte 2 (fallback): parser do arquivo `.wld` no PVC
- Dashboards:
  - `Terraria K8s Overview`
  - `Terraria Gameplay Overview`
- Loki + Promtail
- Argo CD
- Backup de mundo por CronJob

## URLs locais

- Grafana: `http://localhost:30030`
- Prometheus: `http://localhost:30090`
- Argo CD: `http://localhost:30080`
- Terraria (players): `SEU_IP_LAN:30777`

## Compatibilidade de ambiente

O mesmo stack funciona em:

- Windows (PowerShell)
- Linux/WSL2 (Bash)

Requisito em ambos: cluster Kubernetes local ativo (ex.: Docker Desktop Kubernetes), `terraform` e `kubectl` no `PATH`.

## Configuracao

1. Copiar variaveis de exemplo:

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
```

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Editar `terraform/terraform.tfvars` (minimo recomendado):

- `world_file`
- `grafana_admin_password`

3. Opcionais importantes:

- `terraria_api_url` / `terraria_api_token` (API de gameplay)
- `discord_webhook_url` (alertas)
- `grafana_github_oauth_*` (login GitHub no Grafana)
- `terraria_world_parse_interval_seconds`
- `terraria_chest_item_series_limit`

## Deploy (Windows)

```powershell
./scripts/deploy.ps1
```

Com parametros de criacao inicial de mundo:

```powershell
./scripts/deploy.ps1 -WorldName "test.wld" -WorldSize large -MaxPlayers 16 -Difficulty expert -Seed "abc123"
```

## Deploy (Linux / WSL2)

```bash
bash ./scripts/deploy.sh
```

Com parametros de criacao inicial de mundo:

```bash
bash ./scripts/deploy.sh --world-name test.wld --world-size large --max-players 16 --difficulty expert --seed abc123
```

## Upload/criacao de mundo

### Windows

```powershell
# Upload de arquivo existente
./scripts/upload-world.ps1 -WorldFile "C:/caminho/mapa.wld"

# Criacao automatica se nao existir
./scripts/upload-world.ps1 -WorldName "test.wld" -WorldSize medium -MaxPlayers 8 -Difficulty classic -Seed "meu-seed"
```

### Linux / WSL2

```bash
# Upload de arquivo existente
bash ./scripts/upload-world.sh --world-file /c/caminho/mapa.wld

# Criacao automatica se nao existir
bash ./scripts/upload-world.sh --world-name test.wld --world-size medium --max-players 8 --difficulty classic --seed meu-seed
```

### Parametros de criacao suportados

- `WorldSize` / `--world-size`: `small|medium|large`
- `MaxPlayers` / `--max-players`
- `Difficulty` / `--difficulty`: `classic|expert|master|journey`
- `Seed` / `--seed`
- `ServerPort` / `--server-port`
- `ExtraCreateArgs` / `--extra-create-args` (args extras brutos para o `TerrariaServer`)

## Validacao rapida

```bash
kubectl get pods -n terraria
kubectl get pods -n monitoring
kubectl get svc -n terraria
kubectl get svc -n monitoring
```

Queries uteis no Prometheus:

```promql
max(terraria_exporter_source_up)
max(terraria_world_parser_up)
max(terraria_players_online)
max(terraria_world_chests_total)
topk(20, sum by (item) (terraria_chest_item_count_by_item))
probe_success{job="terraria-tcp-probe"}
```

## Quando o dashboard estiver vazio

1. Verifique exporter:

```bash
kubectl -n terraria get pods -l app=terraria-exporter
kubectl -n terraria logs deploy/terraria-exporter --tail=120
```

2. Verifique mundo:

```bash
kubectl -n terraria logs deploy/terraria-server --tail=120
```

3. Se `terraria_exporter_source_up = 0`, o dashboard ainda pode preencher metricas de mundo via parser (`terraria_world_parser_up = 1`) desde que o arquivo `.wld` exista em `/config`.

## Argo CD senha inicial

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

## Destroy

```bash
terraform -chdir=terraform destroy -auto-approve
```