param(
  [string]$Host = "127.0.0.1",
  [int]$Port = 8787,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverPath = Join-Path $repoRoot "world-ui/server.py"
if (-not (Test-Path $serverPath)) {
  throw "world-ui/server.py not found"
}

$pythonExe = $null
$pythonPrefix = @()

if (Get-Command py -ErrorAction SilentlyContinue) {
  $pythonExe = "py"
  $pythonPrefix = @("-3")
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
  $pythonExe = "python"
}

if (-not $pythonExe) {
  throw "Python not found. Install Python 3 and try again."
}

if (-not $NoBrowser) {
  Start-Process "http://$Host`:$Port"
}

& $pythonExe @pythonPrefix $serverPath --host $Host --port $Port

