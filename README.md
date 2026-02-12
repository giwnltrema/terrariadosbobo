# terrariadosbobo

Infra local para subir um servidor **Terraria** em Kubernetes usando **Terraform**, com um pod de jogo e um pod de monitoramento basico (Prometheus + Grafana).

Imagem do servidor: `beardedio/terraria`.

## Arquitetura

- Namespace `terraria`
- Deployment `terraria-server` (1 pod)
- PVC `terraria-config` (persistencia de config/mapas)
- Service `NodePort` para jogadores (padrao `30777`)
- Namespace `monitoring`
- Deployment `monitoring-stack` (1 pod com 2 containers: Prometheus e Grafana)
- Services `NodePort` para UI do Prometheus e Grafana

## Pre-requisitos

1. Windows com WSL2 e Docker Desktop funcionando
2. Kubernetes habilitado no Docker Desktop
3. `kubectl` instalado e apontando para `docker-desktop`
4. Terraform >= 1.6
5. PowerShell como Administrador para abrir firewall

## Estrutura

- `terraform/`: recursos de infra (k8s + services + monitoramento)
- `scripts/deploy.ps1`: init/validate/apply
- `scripts/upload-world.ps1`: copia mapa para o volume do servidor
- `scripts/open-firewall.ps1`: libera portas no firewall do Windows

## Deploy rapido

1. Copie os vars de exemplo:

```powershell
Copy-Item terraform/terraform.tfvars.example terraform/terraform.tfvars
```

2. Ajuste `terraform/terraform.tfvars` (principalmente senha do Grafana e nome do mundo).

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

Observacao: se voce tiver arquivo `.twld` associado ao mundo, envie ele tambem com `kubectl cp` para `/config` no mesmo pod.

## Acesso

- Terraria (amigos): `SEU_IP_LAN:30777` (ou porta definida em `terraria_node_port`)
- Grafana: `http://SEU_IP_LAN:30030`
- Prometheus: `http://SEU_IP_LAN:30090`

Para descobrir seu IP LAN:

```powershell
ipconfig
```

Use o IPv4 da interface da sua rede local (Wi-Fi/Ethernet).

## Operacao diaria

Status dos pods:

```powershell
kubectl get pods -A
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

## Notas importantes

- Esse setup e para uso local/self-hosted.
- Para amigos fora da sua rede local, voce vai precisar encaminhar porta no roteador/NAT e talvez DNS dinamico.
- O monitoramento aqui e basico: Prometheus e Grafana no mesmo pod para simplificar operacao local.
- As imagens estao com tag `latest`; se quiser mais previsibilidade, troque para tags fixas em `terraform/main.tf`.
