# terrariadosbobo

Infra local para subir servidor **Terraria** em Kubernetes com **Terraform** e monitoramento com **Prometheus + Grafana** (incluindo `node-exporter`, `kube-state-metrics` e dashboard pronto para o pod do Terraria).

Imagem do servidor: `beardedio/terraria`.

## Arquitetura

- Namespace `terraria`
- Deployment `terraria-server` (1 pod)
- PVC `terraria-config` (persistencia de config/mapas)
- Service `NodePort` para jogadores (padrao `30777`)
- Namespace `monitoring`
- Helm `kube-prometheus-stack` com:
  - Prometheus Operator
  - Prometheus
  - Grafana
  - `prometheus-node-exporter`
  - `kube-state-metrics`
- `blackbox-exporter` adicional para probe TCP do servidor Terraria
- Dashboard custom `Terraria K8s Overview` provisionado automaticamente no Grafana

## O que voce ganha pronto

- Dashboards padrao do kube-prometheus-stack (cluster, nodes, pods)
- Dashboard custom do Terraria com:
  - CPU do pod
  - Memoria do pod
  - Restarts
  - Reachability TCP (`probe_success`) do servidor na porta 7777

## Limite atual de metricas do Terraria

A imagem `beardedio/terraria` nao expoe endpoint Prometheus nativo de jogo (players online, tick, etc.).
Neste setup, as metricas "especificas" do servidor sao por disponibilidade TCP via blackbox probe.

## Pre-requisitos

1. Windows com WSL2 e Docker Desktop funcionando
2. Kubernetes habilitado no Docker Desktop
3. `kubectl` instalado e apontando para `docker-desktop`
4. Terraform >= 1.6
5. Helm instalado (necessario para o provider Helm do Terraform)
6. PowerShell como Administrador para abrir firewall

## Estrutura

- `terraform/`: recursos de infra (k8s + monitoring)
- `scripts/deploy.ps1`: init/validate/apply
- `scripts/upload-world.ps1`: copia mapa para o volume do servidor
- `scripts/open-firewall.ps1`: libera portas no firewall do Windows

## Deploy rapido

1. Copie os vars de exemplo:

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Ajuste `terraform/terraform.tfvars` (senha do Grafana e nome do mundo).

3. Suba a infra:

```powershell
./scripts/deploy.ps1
```

4. Abra portas no firewall:

```powershell
./scripts/open-firewall.ps1
```

## Como colocar seu mapa (.wld)

1. Suba a stack primeiro (`deploy.ps1`).
2. Rode:

```powershell
./scripts/upload-world.ps1 -WorldFile "C:/caminho/do/seu_mapa.wld"
```

3. Garanta que o `world_file` no `terraform.tfvars` tenha o mesmo nome do arquivo enviado.

## Acesso

- Terraria (amigos): `SEU_IP_LAN:30777` (ou porta definida em `terraria_node_port`)
- Grafana: `http://SEU_IP_LAN:30030`
- Prometheus: `http://SEU_IP_LAN:30090`

Para descobrir seu IP LAN:

```powershell
ipconfig
```

## Operacao diaria

Status:

```powershell
kubectl get pods -A
kubectl get svc -A
```

Logs do Terraria:

```powershell
kubectl logs -n terraria deploy/terraria-server -f
```

Restart do servidor:

```powershell
kubectl rollout restart deployment/terraria-server -n terraria
```

## Desligar tudo

```powershell
terraform -chdir=terraform destroy -auto-approve
```

## Notas

- Setup focado em ambiente local/self-hosted.
- Para amigos fora da LAN: port forwarding no roteador.
- Para metricas de gameplay (players online, boss events etc.), o proximo passo e adicionar um exporter custom ligado ao protocolo/RCON do Terraria.
