param(
  [string]$WorldFile,
  [string]$WorldName,
  [string]$Namespace = "terraria",
  [string]$Deployment = "terraria-server",
  [string]$PvcName = "terraria-config",
  [string]$ManagerPodName = "world-manager",
  [switch]$AutoCreateIfMissing
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

Write-Host "Escalando $Deployment para 0 replicas para manipular o volume..."
kubectl scale deployment/$Deployment -n $Namespace --replicas=0 | Out-Null
kubectl rollout status deployment/$Deployment -n $Namespace --timeout=180s | Out-Null

Write-Host "Subindo pod auxiliar '$ManagerPodName' montando PVC '$PvcName'..."
kubectl delete pod $ManagerPodName -n $Namespace --ignore-not-found=true | Out-Null

$overrides = @"
{
  "spec": {
    "containers": [
      {
        "name": "world-manager",
        "image": "beardedio/terraria:latest",
        "command": ["sh", "-c", "sleep 3600"],
        "volumeMounts": [
          {
            "name": "terraria-config",
            "mountPath": "/config"
          }
        ]
      }
    ],
    "volumes": [
      {
        "name": "terraria-config",
        "persistentVolumeClaim": {
          "claimName": "$PvcName"
        }
      }
    ]
  }
}
"@

kubectl run $ManagerPodName -n $Namespace --image=beardedio/terraria:latest --restart=Never --overrides=$overrides | Out-Null
kubectl wait --for=condition=Ready pod/$ManagerPodName -n $Namespace --timeout=180s | Out-Null

$existsOutput = kubectl exec -n $Namespace $ManagerPodName -- sh -lc "if [ -f '/config/$WorldName' ]; then echo exists; else echo missing; fi"
$worldExists = ($existsOutput.Trim() -eq "exists")

if ($WorldFile) {
  Write-Host "Copiando arquivo '$WorldName' para o PVC..."
  kubectl cp $WorldFile "${Namespace}/${ManagerPodName}:/config/$WorldName" | Out-Null
  $worldExists = $true
}
elseif (-not $worldExists -and $AutoCreateIfMissing) {
  Write-Host "Mundo '$WorldName' nao existe. Criando automaticamente..."

  $createCmd = @"
WORLD_PATH=\"/config/$WorldName\"
WORLD_NAME=\"$worldBaseName\"

./TerrariaServer -x64 -autocreate 2 -world \"\$WORLD_PATH\" -worldname \"\$WORLD_NAME\" -difficulty 0 -maxplayers 8 -port 7777 >/tmp/worldgen.log 2>&1 &
pid=\$!

i=0
while [ \$i -lt 90 ]; do
  if [ -f \"\$WORLD_PATH\" ]; then
    break
  fi
  i=\$((i+1))
  sleep 2
done

kill \$pid >/dev/null 2>&1 || true
wait \$pid >/dev/null 2>&1 || true

if [ ! -f \"\$WORLD_PATH\" ]; then
  echo \"Falha ao criar mundo automaticamente\" >&2
  cat /tmp/worldgen.log >&2 || true
  exit 1
fi
"@

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
