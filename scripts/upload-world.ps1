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
  [string]$ExtraCreateArgs = ""
)

$ErrorActionPreference = "Stop"

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

$safeSeed = $Seed.Replace('\', '\\').Replace('"', '\"')
$safeExtraCreateArgs = $ExtraCreateArgs.Replace('\', '\\').Replace('"', '\"')

Write-Host "Escalando $Deployment para 0 replicas para manipular o volume..."
kubectl scale deployment/$Deployment -n $Namespace --replicas=0 | Out-Null
kubectl rollout status deployment/$Deployment -n $Namespace --timeout=180s | Out-Null

Write-Host "Subindo pod auxiliar '$ManagerPodName' montando PVC '$PvcName'..."
kubectl delete pod $ManagerPodName -n $Namespace --ignore-not-found=true | Out-Null

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
kubectl wait --for=condition=Ready pod/$ManagerPodName -n $Namespace --timeout=180s | Out-Null

$existsOutput = kubectl exec -n $Namespace $ManagerPodName -- sh -lc "if [ -f '/config/$WorldName' ]; then echo exists; else echo missing; fi" 2>$null
if (-not $existsOutput) {
  throw "Falha ao verificar se o mundo existe no PVC."
}

$worldExists = ($existsOutput.Trim() -eq "exists")

if ($WorldFile) {
  Write-Host "Copiando arquivo '$WorldName' para o PVC..."
  kubectl cp $WorldFile "${Namespace}/${ManagerPodName}:/config/$WorldName" | Out-Null
  $worldExists = $true
}
elseif (-not $worldExists -and $AutoCreateIfMissing) {
  Write-Host "Mundo '$WorldName' nao existe. Criando automaticamente (size=$WorldSize, difficulty=$Difficulty, maxplayers=$MaxPlayers)..."

  $createCmd = @"
WORLD_PATH=\"/config/__WORLD_FILE__\"
WORLD_NAME=\"__WORLD_BASE__\"
WORLD_SIZE=\"__WORLD_SIZE__\"
WORLD_DIFFICULTY=\"__WORLD_DIFFICULTY__\"
MAX_PLAYERS=\"__MAX_PLAYERS__\"
SERVER_PORT=\"__SERVER_PORT__\"
WORLD_SEED=\"__WORLD_SEED__\"
EXTRA_CREATE_ARGS=\"__EXTRA_CREATE_ARGS__\"

CMD=\"./TerrariaServer -x64 -autocreate `$WORLD_SIZE -world \\\"`$WORLD_PATH\\\" -worldname \\\"`$WORLD_NAME\\\" -difficulty `$WORLD_DIFFICULTY -maxplayers `$MAX_PLAYERS -port `$SERVER_PORT\"
if [ -n \"`$WORLD_SEED\" ]; then
  CMD=\"`$CMD -seed \\\"`$WORLD_SEED\\\"\"
fi
if [ -n \"`$EXTRA_CREATE_ARGS\" ]; then
  CMD=\"`$CMD `$EXTRA_CREATE_ARGS\"
fi

eval \"`$CMD >/tmp/worldgen.log 2>&1 &\"
pid=`$!

i=0
while [ `$i -lt 120 ]; do
  if [ -f \"`$WORLD_PATH\" ]; then
    break
  fi
  i=`$((i+1))
  sleep 2
done

kill `$pid >/dev/null 2>&1 || true
wait `$pid >/dev/null 2>&1 || true

if [ ! -f \"`$WORLD_PATH\" ]; then
  echo \"Falha ao criar mundo automaticamente\" >&2
  cat /tmp/worldgen.log >&2 || true
  exit 1
fi
"@

  $createCmd = $createCmd.Replace("__WORLD_FILE__", $WorldName)
  $createCmd = $createCmd.Replace("__WORLD_BASE__", $worldBaseName)
  $createCmd = $createCmd.Replace("__WORLD_SIZE__", [string]$worldSizeNumber)
  $createCmd = $createCmd.Replace("__WORLD_DIFFICULTY__", [string]$difficultyNumber)
  $createCmd = $createCmd.Replace("__MAX_PLAYERS__", [string]$MaxPlayers)
  $createCmd = $createCmd.Replace("__SERVER_PORT__", [string]$ServerPort)
  $createCmd = $createCmd.Replace("__WORLD_SEED__", $safeSeed)
  $createCmd = $createCmd.Replace("__EXTRA_CREATE_ARGS__", $safeExtraCreateArgs)

  kubectl exec -n $Namespace $ManagerPodName -- sh -lc $createCmd | Out-Null
  $worldExists = $true
}

if (-not $worldExists) {
  throw "Mundo '$WorldName' nao existe no PVC e AutoCreateIfMissing foi desativado."
}

Write-Host "Limpando pod auxiliar..."
kubectl delete pod $ManagerPodName -n $Namespace --ignore-not-found=true | Out-Null

Write-Host "Subindo deployment $Deployment com mundo '$WorldName'..."
kubectl scale deployment/$Deployment -n $Namespace --replicas=1 | Out-Null
kubectl rollout status deployment/$Deployment -n $Namespace --timeout=300s | Out-Null

Write-Host "Mundo pronto: $WorldName"