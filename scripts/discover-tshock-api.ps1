param(
  [string]$BaseUrl = "http://localhost:7878",
  [string]$Token = ""
)

$ErrorActionPreference = "Stop"

$paths = @(
  "/status",
  "/v2/status",
  "/v2/server/status",
  "/players",
  "/v2/players",
  "/v2/players/list",
  "/world",
  "/v2/world",
  "/v2/world/status",
  "/monsters",
  "/v2/monsters/list",
  "/v2/npcs/list",
  "/v2/world/chests",
  "/v2/world/houses",
  "/v2/world/housednpcs",
  "/v2/npcs/housed"
)

$params = @{}
if ($Token) {
  $params.token = $Token
}

foreach ($path in $paths) {
  $uri = "$BaseUrl$path"
  try {
    $r = Invoke-WebRequest -Uri $uri -Method GET -TimeoutSec 8 -Body $null -ErrorAction Stop
    Write-Host "[OK] $path -> HTTP $($r.StatusCode)"
  }
  catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status) {
      Write-Host "[NO] $path -> HTTP $status"
    }
    else {
      Write-Host "[NO] $path -> sem resposta"
    }
  }
}
