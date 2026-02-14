param(
  [int]$TerrariaPort = 30777,
  [int]$GrafanaPort = 30030,
  [int]$PrometheusPort = 30090,
  [int]$ArgoCdPort = 30080
)

$ErrorActionPreference = "Stop"

$rules = @(
  @{ Name = "Terraria Server"; Port = $TerrariaPort },
  @{ Name = "Grafana"; Port = $GrafanaPort },
  @{ Name = "Prometheus"; Port = $PrometheusPort },
  @{ Name = "ArgoCD"; Port = $ArgoCdPort }
)

foreach ($rule in $rules) {
  $displayName = "terrariadosbobo-$($rule.Name)-$($rule.Port)"

  if (-not (Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $displayName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $rule.Port | Out-Null
    Write-Host "Regra criada: $displayName"
  }
  else {
    Write-Host "Regra ja existe: $displayName"
  }
}
