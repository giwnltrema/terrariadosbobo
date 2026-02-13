param(
  [string]$TerraformDir = "terraform",
  [string]$KubeContext = "docker-desktop",
  [string]$WorldFile,
  [string]$WorldName,
  [switch]$SkipWorldEnsure
)

$ErrorActionPreference = "Stop"

function Get-WorldNameFromTfvars {
  param(
    [string]$Path
  )

  if (-not (Test-Path $Path)) {
    return $null
  }

  $line = Get-Content $Path | Where-Object { $_ -match '^\s*world_file\s*=\s*"(.+)"\s*$' } | Select-Object -First 1
  if (-not $line) {
    return $null
  }

  $match = [regex]::Match($line, '^\s*world_file\s*=\s*"(.+)"\s*$')
  if ($match.Success) {
    return $match.Groups[1].Value
  }

  return $null
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  throw "Terraform nao encontrado no PATH. Instale ou ajuste o PATH da sessao antes de rodar este script."
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw "kubectl nao encontrado no PATH."
}

if (-not (Test-Path $TerraformDir)) {
  throw "Diretorio Terraform nao encontrado: $TerraformDir"
}

$currentContext = kubectl config current-context 2>$null
if (-not $currentContext) {
  throw "Nao foi possivel ler o contexto atual do kubectl."
}

if ($currentContext.Trim() -ne $KubeContext) {
  Write-Host "[0/6] Ajustando contexto para $KubeContext"
  kubectl config use-context $KubeContext | Out-Null
}

Write-Host "[0/6] Validando conectividade do cluster"
kubectl cluster-info | Out-Null
kubectl get nodes | Out-Null

Write-Host "[1/6] terraform init"
terraform "-chdir=$TerraformDir" init

Write-Host "[2/6] terraform validate"
terraform "-chdir=$TerraformDir" validate

$probeCrdExists = $true
kubectl get crd probes.monitoring.coreos.com 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
  $probeCrdExists = $false
}

if (-not $probeCrdExists) {
  Write-Host "[3/6] Bootstrap do kube-prometheus-stack (CRDs)"
  terraform "-chdir=$TerraformDir" apply -target=helm_release.kube_prometheus_stack -auto-approve
}
else {
  Write-Host "[3/6] CRDs de monitoring ja existem, pulando bootstrap"
}

Write-Host "[4/6] terraform apply"
terraform "-chdir=$TerraformDir" apply -auto-approve

if (-not $SkipWorldEnsure) {
  $resolvedWorldName = $WorldName

  if (-not $resolvedWorldName) {
    $resolvedWorldName = Get-WorldNameFromTfvars -Path (Join-Path $TerraformDir "terraform.tfvars")
  }

  if (-not $resolvedWorldName -and $WorldFile) {
    $resolvedWorldName = [System.IO.Path]::GetFileName($WorldFile)
  }

  if (-not $resolvedWorldName) {
    $resolvedWorldName = "test.wld"
  }

  Write-Host "[5/6] Garantindo mundo '$resolvedWorldName' no PVC"
  $uploadScript = Join-Path $PSScriptRoot "upload-world.ps1"

  if ($WorldFile) {
    & $uploadScript -WorldFile $WorldFile -WorldName $resolvedWorldName
  }
  else {
    & $uploadScript -WorldName $resolvedWorldName
  }
}
else {
  Write-Host "[5/6] SkipWorldEnsure ativo, pulando gerenciamento de mundo"
}

Write-Host "[6/6] Estado dos recursos"
kubectl get pods -A
kubectl get svc -A
