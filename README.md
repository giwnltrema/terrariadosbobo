# terrariadosbobo

Servidor local de Terraria em Kubernetes com provisionamento via Terraform e observabilidade pronta com Prometheus + Grafana.

## Visao Geral

Este repositório sobe, no seu ambiente local (Docker Desktop + Kubernetes):

- servidor Terraria (`beardedio/terraria`)
- persistencia de mundo/config via PVC
- monitoramento com `kube-prometheus-stack`
- `node-exporter` e `kube-state-metrics`
- `blackbox-exporter` para probe TCP do servidor Terraria
- dashboard custom `Terraria K8s Overview` no Grafana

## Arquitetura

### Namespace `terraria`

- Deployment: `terraria-server` (1 replica)
- PVC: `terraria-config` (5Gi)
- Service: `terraria-service` (`NodePort`, padrao `30777`)

### Namespace `monitoring`

- Helm release: `kube-prom-stack` (`kube-prometheus-stack`)
- Prometheus (`NodePort`, padrao `30090`)
- Grafana (`NodePort`, padrao `30030`)
- `prometheus-node-exporter`
- `kube-state-metrics`
- `blackbox-exporter` + CRD `Probe` para monitorar TCP `terraria-service:7777`

## O que ja vem pronto

- Dashboards padrao do kube-prometheus-stack (cluster/nodes/pods)
- Dashboard custom `Terraria K8s Overview` com:
  - CPU do pod do Terraria
  - memoria do pod do Terraria
  - reinicios do pod
  - disponibilidade TCP (`probe_success`) da porta 7777

## Limites de metricas especificas do jogo

A imagem `beardedio/terraria` nao expõe endpoint Prometheus nativo para metricas de gameplay (players online, eventos etc.).
Neste setup, a parte "especifica" do jogo e disponibilidade TCP e saude operacional do pod.

## Pre-requisitos

1. Windows com WSL2 e Docker Desktop funcionando
2. Kubernetes habilitado no Docker Desktop
3. `kubectl` instalado e com contexto `docker-desktop`
4. Terraform >= 1.6 instalado no PATH
5. PowerShell (rodar como Admin para firewall)

## Estrutura do Projeto

- `terraform/providers.tf`: providers Terraform (`kubernetes`, `helm`)
- `terraform/variables.tf`: variaveis de ambiente/portas/credenciais
- `terraform/main.tf`: recursos Kubernetes e Helm
- `terraform/outputs.tf`: endpoints e dicas de acesso
- `terraform/terraform.tfvars.example`: template de variaveis
- `scripts/deploy.ps1`: valida cluster, bootstrap de CRDs, apply e garantia de mundo
- `scripts/upload-world.ps1`: envia `.wld` para o PVC ou cria mundo automaticamente se nao existir
- `scripts/open-firewall.ps1`: regras de entrada no Firewall do Windows

## Primeira Subida (Do Zero)

### 1. Preparar variaveis

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
notepad terraform/terraform.tfvars
```

Ajuste no minimo:

- `world_file` (nome exato do arquivo `.wld`)
- `grafana_admin_password`
- portas (se quiser mudar)

### 2. Deploy da stack

```powershell
./scripts/deploy.ps1
```

### 3. Abrir firewall local (Admin)

```powershell
./scripts/open-firewall.ps1
```

### 4. Mundo (automatico ou arquivo proprio)\n\nSe o mundo configurado em `world_file` nao existir no PVC, o `deploy.ps1` ja cria automaticamente.\n\nSe quiser usar um mapa seu, rode:\n\n```powershell\n./scripts/upload-world.ps1 -WorldFile "C:/caminho/do/seu_mapa.wld"\n```\n\nImportante: o nome do arquivo enviado deve bater com `world_file` no `terraform.tfvars`.\n

## Acesso e URLs

- Terraria: `SEU_IP_LAN:30777` (ou porta configurada)
- Grafana: `http://SEU_IP_LAN:30030`
- Prometheus: `http://SEU_IP_LAN:30090`

Para descobrir IP LAN:

```powershell
ipconfig
```

Use o IPv4 da interface ativa (Wi-Fi ou Ethernet).

## Operacao Diaria

### Verificar saude

```powershell
kubectl get pods -A
kubectl get svc -A
```

### Logs do servidor

```powershell
kubectl logs -n terraria deploy/terraria-server -f
```

### Reiniciar Terraria

```powershell
kubectl rollout restart deployment/terraria-server -n terraria
kubectl rollout status deployment/terraria-server -n terraria
```

### Reaplicar alteracoes Terraform

```powershell
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

## Dashboards e Queries Uteis

No Grafana, abra:

- `Terraria K8s Overview`
- dashboards padrao de Kubernetes (CPU/RAM de nodes e pods)

Queries PromQL uteis:

- disponibilidade TCP do server:

```promql
probe_success{job="terraria-tcp-probe"}
```

- CPU do pod do Terraria:

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="terraria",pod=~"terraria-server-.*",container!=""}[5m]))
```

- memoria do pod do Terraria:

```promql
sum(container_memory_working_set_bytes{namespace="terraria",pod=~"terraria-server-.*",container!=""})
```

## Troubleshooting

### `terraform` nao reconhecido

Instale Terraform e abra um novo terminal.

### Pod do Terraria nao sobe

```powershell
kubectl describe pod -n terraria -l app=terraria-server
kubectl logs -n terraria deploy/terraria-server
```

Cheque tambem se o nome de `world_file` existe em `/config`.

### Grafana sem dashboard custom

```powershell
kubectl get configmap -n monitoring terraria-dashboards -o yaml
kubectl get pods -n monitoring
```

Aguarde alguns minutos apos o primeiro deploy para sidecar importar dashboards.

### Amigos nao conseguem conectar

1. Validar `NodePort` no service do Terraria
2. Validar regra do Firewall (`scripts/open-firewall.ps1`)
3. Confirmar IP LAN correto
4. Se for acesso externo (fora da sua rede), configurar port forwarding no roteador

## Atualizar Imagens

As imagens estao em `latest`. Para fixar versoes, altere em `terraform/main.tf`:

- `beardedio/terraria:latest`
- `prom/blackbox-exporter:v0.25.0`
- chart `kube-prometheus-stack` (via Helm release)

Depois:

```powershell
terraform -chdir=terraform apply
```

## Destroy (Remover Tudo)

```powershell
terraform -chdir=terraform destroy -auto-approve
```

## Proximos Passos Recomendados

1. Adicionar exporter custom para metricas de gameplay (players online etc.)
2. Trocar imagens `latest` por tags fixas
3. Persistir dados do Prometheus/Grafana com PVC
4. Configurar backup automatizado do mundo `.wld`

