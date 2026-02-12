param(
  [Parameter(Mandatory = $true)]
  [string]$WorldFile,
  [string]$Namespace = "terraria",
  [string]$Deployment = "terraria-server"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $WorldFile)) {
  throw "Arquivo nao encontrado: $WorldFile"
}

$pod = kubectl get pods -n $Namespace -l app=terraria-server -o jsonpath='{.items[0].metadata.name}'
if (-not $pod) {
  throw "Pod do Terraria nao encontrado no namespace $Namespace"
}

$worldName = [System.IO.Path]::GetFileName($WorldFile)

Write-Host "Copiando $worldName para /config/$worldName"
kubectl cp $WorldFile "${Namespace}/${pod}:/config/$worldName"

Write-Host "Reiniciando deployment para recarregar mundo"
kubectl rollout restart deployment/$Deployment -n $Namespace
kubectl rollout status deployment/$Deployment -n $Namespace

Write-Host "Upload finalizado. Mundo ativo: $worldName"
