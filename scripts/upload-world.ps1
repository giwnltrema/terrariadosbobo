param(
  [string]$WorldFile,
  [string]$WorldName,
  [string]$Namespace = "terraria",
  [string]$Deployment = "terraria-server",
  [string]$PvcName = "terraria-config",
  [string]$ManagerPodName = "world-manager",
  [string]$ManagerImage = "ghcr.io/beardedio/terraria:tshock-latest",
  [switch]$AutoCreateIfMissing,
  [ValidateSet("small", "medium", "large")]
  [string]$WorldSize = "medium",
  [ValidateRange(1, 255)]
  [int]$MaxPlayers = 8,
  [ValidateSet("classic", "expert", "master", "journey")]
  [string]$Difficulty = "classic",
  [string]$Seed = "",
  [ValidateRange(1, 65535)]
  [int]$ServerPort = 7777,
  [string]$ExtraCreateArgs = "",
  [ValidateRange(60, 7200)]
  [int]$WorldCreateTimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

function Invoke-Kubectl {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Args,
    [string]$ErrorMessage = "Falha ao executar kubectl"
  )

  $output = & kubectl @Args
  if ($LASTEXITCODE -ne 0) {
    throw "$ErrorMessage (exit code: $LASTEXITCODE)"
  }
  return $output
}

if (-not $AutoCreateIfMissing.IsPresent) {
  $AutoCreateIfMissing = $true
}

if ($WorldFile -and -not (Test-Path $WorldFile)) {
  throw "Arquivo nao encontrado: $WorldFile"
}

if ($WorldFile) {
  $fileWorldName = [System.IO.Path]::GetFileName($WorldFile)
  if ($WorldName -and $WorldName -ne $fileWorldName) {
    throw "WorldName ($WorldName) difere do nome do arquivo enviado ($fileWorldName)."
  }
  $WorldName = $fileWorldName
}

if (-not $WorldName) {
  throw "Informe -WorldName (ou -WorldFile)."
}

$worldBaseName = [System.IO.Path]::GetFileNameWithoutExtension($WorldName)
$worldSizeNumber = @{ small = 1; medium = 2; large = 3 }[$WorldSize]
$difficultyNumber = @{ classic = 0; expert = 1; master = 2; journey = 3 }[$Difficulty]

Write-Host "Escalando $Deployment para 0 replicas para manipular o volume..."
Invoke-Kubectl -Args @("-n", $Namespace, "scale", "deployment/$Deployment", "--replicas=0") -ErrorMessage "Falha ao escalar deployment para 0" | Out-Null
Invoke-Kubectl -Args @("-n", $Namespace, "rollout", "status", "deployment/$Deployment", "--timeout=180s") -ErrorMessage "Falha aguardando deployment em 0 replicas" | Out-Null

Write-Host "Subindo pod auxiliar '$ManagerPodName' montando PVC '$PvcName'..."
& kubectl -n $Namespace delete pod $ManagerPodName --ignore-not-found=true | Out-Null

$manifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $ManagerPodName
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
    - name: world-manager
      image: $ManagerImage
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: terraria-config
          mountPath: /config
  volumes:
    - name: terraria-config
      persistentVolumeClaim:
        claimName: $PvcName
"@

$manifest | kubectl apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Falha ao criar pod auxiliar '$ManagerPodName'"
}

Invoke-Kubectl -Args @("-n", $Namespace, "wait", "--for=condition=Ready", "pod/$ManagerPodName", "--timeout=180s") -ErrorMessage "Pod auxiliar nao ficou Ready" | Out-Null

$existsOutput = & kubectl -n $Namespace exec $ManagerPodName -- sh -lc "if [ -f '/config/$WorldName' ]; then echo exists; else echo missing; fi" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $existsOutput) {
  throw "Falha ao verificar se o mundo existe no PVC."
}

$worldExists = ($existsOutput.Trim() -eq "exists")

if ($WorldFile) {
  Write-Host "Copiando arquivo '$WorldName' para o PVC..."
  Invoke-Kubectl -Args @("-n", $Namespace, "cp", $WorldFile, "${ManagerPodName}:/config/$WorldName") -ErrorMessage "Falha ao copiar arquivo de mundo" | Out-Null
  $worldExists = $true
}
elseif (-not $worldExists -and $AutoCreateIfMissing) {
  Write-Host "Mundo '$WorldName' nao existe. Criando automaticamente (size=$WorldSize, difficulty=$Difficulty, maxplayers=$MaxPlayers)..."

  $createScript = @(
    'set -eu',
    '',
    'WORLD_PATH="$1"',
    'WORLD_NAME="$2"',
    'WORLD_SIZE="$3"',
    'WORLD_DIFFICULTY="$4"',
    'MAX_PLAYERS="$5"',
    'SERVER_PORT="$6"',
    'WORLD_SEED="$7"',
    'EXTRA_CREATE_ARGS="$8"',
    'CREATE_TIMEOUT_SECONDS="$9"',
    '',
    'resolve_bin() {',
    '  if [ -x /tshock/TShock.Server ]; then',
    '    echo "/tshock/TShock.Server"',
    '    return',
    '  fi',
    '  if [ -x /tshock/TerrariaServer ]; then',
    '    echo "/tshock/TerrariaServer"',
    '    return',
    '  fi',
    '  if command -v TShock.Server >/dev/null 2>&1; then',
    '    command -v TShock.Server',
    '    return',
    '  fi',
    '  if command -v TerrariaServer >/dev/null 2>&1; then',
    '    command -v TerrariaServer',
    '    return',
    '  fi',
    '  if [ -x ./TerrariaServer ]; then',
    '    echo "./TerrariaServer"',
    '    return',
    '  fi',
    '  echo "Nenhum binario de servidor encontrado para autocreate." >&2',
    '  return 1',
    '}',
    '',
    'SERVER_BIN="$(resolve_bin)"',
    'CMD="$SERVER_BIN -autocreate \"$WORLD_SIZE\" -world \"$WORLD_PATH\" -worldname \"$WORLD_NAME\" -difficulty \"$WORLD_DIFFICULTY\" -maxplayers \"$MAX_PLAYERS\" -port \"$SERVER_PORT\""',
    '',
    'if [ -n "$WORLD_SEED" ]; then',
    '  CMD="$CMD -seed \"$WORLD_SEED\""',
    'fi',
    '',
    'if [ -n "$EXTRA_CREATE_ARGS" ]; then',
    '  CMD="$CMD $EXTRA_CREATE_ARGS"',
    'fi',
    '',
    'rm -f "$WORLD_PATH"',
    'sh -c "$CMD >/tmp/worldgen.log 2>&1" &',
    'pid=$!',
    '',
    'elapsed=0',
    'while [ "$elapsed" -lt "$CREATE_TIMEOUT_SECONDS" ]; do',
    '  if [ -s "$WORLD_PATH" ]; then',
    '    break',
    '  fi',
    '  if ! kill -0 "$pid" 2>/dev/null; then',
    '    break',
    '  fi',
    '  sleep 2',
    '  elapsed=$((elapsed+2))',
    'done',
    '',
    'if [ -s "$WORLD_PATH" ]; then',
    '  kill $pid >/dev/null 2>&1 || true',
    '  wait $pid >/dev/null 2>&1 || true',
    '  exit 0',
    'fi',
    '',
    'if kill -0 "$pid" 2>/dev/null; then',
    '  kill $pid >/dev/null 2>&1 || true',
    'fi',
    'wait $pid >/dev/null 2>&1 || true',
    '',
    'echo "Falha ao criar mundo automaticamente" >&2',
    'echo "--- /tmp/worldgen.log ---" >&2',
    'cat /tmp/worldgen.log >&2 || true',
    'exit 1'
  ) -join "`n"

  $createScript |
    & kubectl exec -i -n $Namespace $ManagerPodName -- sh -s -- "/config/$WorldName" $worldBaseName ([string]$worldSizeNumber) ([string]$difficultyNumber) ([string]$MaxPlayers) ([string]$ServerPort) $Seed $ExtraCreateArgs ([string]$WorldCreateTimeoutSeconds) |
    Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "Falha na criacao automatica do mundo '$WorldName'."
  }

  $worldExists = $true
}

if (-not $worldExists) {
  throw "Mundo '$WorldName' nao existe no PVC e AutoCreateIfMissing foi desativado."
}

Write-Host "Limpando pod auxiliar..."
& kubectl -n $Namespace delete pod $ManagerPodName --ignore-not-found=true | Out-Null

Write-Host "Configurando deployment $Deployment para usar mundo '$WorldName'..."
Invoke-Kubectl -Args @("-n", $Namespace, "set", "env", "deployment/$Deployment", "world=$WorldName", "worldpath=/config") -ErrorMessage "Falha ao configurar env world/worldpath no deployment" | Out-Null

Write-Host "Subindo deployment $Deployment com mundo '$WorldName'..."
Invoke-Kubectl -Args @("-n", $Namespace, "scale", "deployment/$Deployment", "--replicas=1") -ErrorMessage "Falha ao escalar deployment para 1" | Out-Null

$rolloutOk = $true
try {
  Invoke-Kubectl -Args @("-n", $Namespace, "rollout", "status", "deployment/$Deployment", "--timeout=300s") -ErrorMessage "Falha aguardando deployment ficar Ready" | Out-Null
}
catch {
  $rolloutOk = $false
  Write-Host "Rollout falhou para deployment/$Deployment. Diagnostico rapido:" -ForegroundColor Yellow
  & kubectl -n $Namespace get pods -l app=terraria-server -o wide
  & kubectl -n $Namespace logs deployment/$Deployment --tail=120
  throw
}

if ($rolloutOk) {
  Write-Host "Mundo pronto: $WorldName"
}
