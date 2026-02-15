param(
  [string]$Host = "127.0.0.1",
  [int]$Port = 8787,
  [switch]$NoBrowser,
  [switch]$K8s,
  [string]$K8sNamespace = "terraria",
  [string]$K8sApp = "world-creator-ui",
  [int]$K8sNodePort = 30878,
  [switch]$K8sDelete
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Command {
  param([string]$Name)
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name not found in PATH."
  }
}

function Open-Url {
  param([string]$Url)
  if (-not $NoBrowser) {
    Start-Process $Url | Out-Null
  }
}

function Build-WorldUiManifest {
  param(
    [string]$Namespace,
    [string]$AppName,
    [int]$NodePort
  )

  return @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $AppName
  namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $AppName
  namespace: $Namespace
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["get", "create"]
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $AppName
  namespace: $Namespace
subjects:
  - kind: ServiceAccount
    name: $AppName
    namespace: $Namespace
roleRef:
  kind: Role
  name: $AppName
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $AppName
  namespace: $Namespace
  labels:
    app: $AppName
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $AppName
  template:
    metadata:
      labels:
        app: $AppName
    spec:
      serviceAccountName: $AppName
      containers:
        - name: $AppName
          image: alpine:3.20
          ports:
            - containerPort: 8787
              name: http
          command: ["sh", "-lc"]
          args:
            - |
              set -eu
              apk add --no-cache bash python3 py3-pip kubectl >/dev/null
              mkdir -p /workspace/world-ui/static /workspace/scripts
              cp /config/server.py /workspace/world-ui/server.py
              cp /config/index.html /workspace/world-ui/static/index.html
              cp /config/styles.css /workspace/world-ui/static/styles.css
              cp /config/app.js /workspace/world-ui/static/app.js
              cp /config/upload-world.sh /workspace/scripts/upload-world.sh
              chmod +x /workspace/scripts/upload-world.sh
              cd /workspace
              exec env PYTHONUNBUFFERED=1 python3 /workspace/world-ui/server.py --host 0.0.0.0 --port 8787
          volumeMounts:
            - name: world-ui-code
              mountPath: /config
      volumes:
        - name: world-ui-code
          configMap:
            name: $AppName-code
---
apiVersion: v1
kind: Service
metadata:
  name: $AppName
  namespace: $Namespace
  labels:
    app: $AppName
spec:
  type: NodePort
  selector:
    app: $AppName
  ports:
    - name: http
      port: 8787
      targetPort: 8787
      nodePort: $NodePort
"@
}

function Deploy-K8sUi {
  param(
    [string]$Namespace,
    [string]$AppName,
    [int]$NodePort
  )

  Assert-Command kubectl
  kubectl get ns $Namespace 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) {
    kubectl create ns $Namespace | Out-Null
  }

  $serverPy = Join-Path $repoRoot "world-ui/server.py"
  $indexHtml = Join-Path $repoRoot "world-ui/static/index.html"
  $stylesCss = Join-Path $repoRoot "world-ui/static/styles.css"
  $appJs = Join-Path $repoRoot "world-ui/static/app.js"
  $uploadScript = Join-Path $repoRoot "scripts/upload-world.sh"

  if (-not (Test-Path $serverPy)) { throw "Missing file: $serverPy" }
  if (-not (Test-Path $indexHtml)) { throw "Missing file: $indexHtml" }
  if (-not (Test-Path $stylesCss)) { throw "Missing file: $stylesCss" }
  if (-not (Test-Path $appJs)) { throw "Missing file: $appJs" }
  if (-not (Test-Path $uploadScript)) { throw "Missing file: $uploadScript" }

  & kubectl -n $Namespace create configmap "$AppName-code" `
    "--from-file=server.py=$serverPy" `
    "--from-file=index.html=$indexHtml" `
    "--from-file=styles.css=$stylesCss" `
    "--from-file=app.js=$appJs" `
    "--from-file=upload-world.sh=$uploadScript" `
    --dry-run=client -o yaml |
    & kubectl apply -f - | Out-Null

  $manifest = Build-WorldUiManifest -Namespace $Namespace -AppName $AppName -NodePort $NodePort
  $manifest | & kubectl apply -f - | Out-Null
  & kubectl -n $Namespace rollout status "deployment/$AppName" --timeout=300s | Out-Null

  $url = "http://localhost:$NodePort"
  Open-Url -Url $url

  Write-Host "[world-ui] Kubernetes mode enabled"
  Write-Host "[world-ui] Namespace: $Namespace"
  Write-Host "[world-ui] Deployment: $AppName"
  Write-Host "[world-ui] URL: $url"
  Write-Host "[world-ui] Remove with: ./scripts/world-creator-ui.ps1 -K8s -K8sDelete"
}

function Delete-K8sUi {
  param(
    [string]$Namespace,
    [string]$AppName
  )

  Assert-Command kubectl
  & kubectl -n $Namespace delete service $AppName --ignore-not-found | Out-Null
  & kubectl -n $Namespace delete deployment $AppName --ignore-not-found | Out-Null
  & kubectl -n $Namespace delete role $AppName --ignore-not-found | Out-Null
  & kubectl -n $Namespace delete rolebinding $AppName --ignore-not-found | Out-Null
  & kubectl -n $Namespace delete serviceaccount $AppName --ignore-not-found | Out-Null
  & kubectl -n $Namespace delete configmap "$AppName-code" --ignore-not-found | Out-Null
  Write-Host "[world-ui] Kubernetes resources removed from namespace '$Namespace'."
}

if ($K8s) {
  if ($K8sDelete) {
    Delete-K8sUi -Namespace $K8sNamespace -AppName $K8sApp
    exit 0
  }
  Deploy-K8sUi -Namespace $K8sNamespace -AppName $K8sApp -NodePort $K8sNodePort
  exit 0
}

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

$url = "http://$Host`:$Port"
Open-Url -Url $url

Write-Host "[world-ui] Terraria World Creator UI"
Write-Host "[world-ui] URL: $url"
Write-Host "[world-ui] Press Ctrl+C to stop."

& $pythonExe @pythonPrefix $serverPath --host $Host --port $Port
