#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="8787"
NO_BROWSER="${NO_BROWSER:-0}"
USE_K8S="0"
K8S_NAMESPACE="terraria"
K8S_APP="world-creator-ui"
K8S_NODE_PORT="30878"

usage() {
  cat <<USAGE
Usage: scripts/world-creator-ui.sh [options]

Options:
  --host HOST          (local mode, default: 127.0.0.1)
  --port PORT          (local mode, default: 8787)
  --no-browser
  --k8s                deploy UI as Kubernetes Deployment + NodePort
  --k8s-namespace NS   (default: terraria)
  --k8s-node-port N    (default: 30878)
  --k8s-delete         remove Kubernetes resources and exit
USAGE
}

delete_k8s() {
  local ns="$1"
  local app="$2"

  kubectl -n "$ns" delete service "$app" --ignore-not-found >/dev/null || true
  kubectl -n "$ns" delete deployment "$app" --ignore-not-found >/dev/null || true
  kubectl -n "$ns" delete role "$app" --ignore-not-found >/dev/null || true
  kubectl -n "$ns" delete rolebinding "$app" --ignore-not-found >/dev/null || true
  kubectl -n "$ns" delete serviceaccount "$app" --ignore-not-found >/dev/null || true
  kubectl -n "$ns" delete configmap "$app-code" --ignore-not-found >/dev/null || true

  echo "[world-ui] Kubernetes resources removed from namespace '$ns'."
}

deploy_k8s() {
  local ns="$1"
  local app="$2"
  local node_port="$3"
  local repo_root="$4"

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not found in PATH." >&2
    exit 1
  fi

  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null

  kubectl -n "$ns" create configmap "$app-code" \
    --from-file=server.py="$repo_root/world-ui/server.py" \
    --from-file=index.html="$repo_root/world-ui/static/index.html" \
    --from-file=styles.css="$repo_root/world-ui/static/styles.css" \
    --from-file=app.js="$repo_root/world-ui/static/app.js" \
    --from-file=upload-world.sh="$repo_root/scripts/upload-world.sh" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${app}
  namespace: ${ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${app}
  namespace: ${ns}
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
  name: ${app}
  namespace: ${ns}
subjects:
  - kind: ServiceAccount
    name: ${app}
    namespace: ${ns}
roleRef:
  kind: Role
  name: ${app}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${app}
  namespace: ${ns}
  labels:
    app: ${app}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${app}
  template:
    metadata:
      labels:
        app: ${app}
    spec:
      serviceAccountName: ${app}
      containers:
        - name: ${app}
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
            name: ${app}-code
---
apiVersion: v1
kind: Service
metadata:
  name: ${app}
  namespace: ${ns}
  labels:
    app: ${app}
spec:
  type: NodePort
  selector:
    app: ${app}
  ports:
    - name: http
      port: 8787
      targetPort: 8787
      nodePort: ${node_port}
EOF

  kubectl -n "$ns" rollout status "deployment/$app" --timeout=300s >/dev/null

  local url="http://localhost:${node_port}"

  if [[ "$NO_BROWSER" != "1" ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
      (xdg-open "$url" >/dev/null 2>&1 || true) &
    elif command -v open >/dev/null 2>&1; then
      (open "$url" >/dev/null 2>&1 || true) &
    elif command -v cmd.exe >/dev/null 2>&1; then
      (cmd.exe /c start "" "$url" >/dev/null 2>&1 || true) &
    fi
  fi

  echo "[world-ui] Kubernetes mode enabled"
  echo "[world-ui] Namespace: $ns"
  echo "[world-ui] Deployment: $app"
  echo "[world-ui] URL: $url"
  echo "[world-ui] To remove: bash ./scripts/world-creator-ui.sh --k8s --k8s-delete"
}

DELETE_K8S="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --no-browser)
      NO_BROWSER="1"; shift ;;
    --k8s)
      USE_K8S="1"; shift ;;
    --k8s-namespace)
      K8S_NAMESPACE="$2"; shift 2 ;;
    --k8s-node-port)
      K8S_NODE_PORT="$2"; shift 2 ;;
    --k8s-delete)
      DELETE_K8S="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_PATH="$REPO_ROOT/world-ui/server.py"

if [[ "$USE_K8S" == "1" ]]; then
  if [[ "$DELETE_K8S" == "1" ]]; then
    delete_k8s "$K8S_NAMESPACE" "$K8S_APP"
    exit 0
  fi
  deploy_k8s "$K8S_NAMESPACE" "$K8S_APP" "$K8S_NODE_PORT" "$REPO_ROOT"
  exit 0
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Python not found. Install Python 3 and try again." >&2
  exit 1
fi

if [[ ! -f "$SERVER_PATH" ]]; then
  echo "world-ui/server.py not found" >&2
  exit 1
fi

if [[ "$NO_BROWSER" != "1" ]]; then
  URL="http://$HOST:$PORT"
  if command -v xdg-open >/dev/null 2>&1; then
    (xdg-open "$URL" >/dev/null 2>&1 || true) &
  elif command -v open >/dev/null 2>&1; then
    (open "$URL" >/dev/null 2>&1 || true) &
  elif command -v cmd.exe >/dev/null 2>&1; then
    (cmd.exe /c start "" "$URL" >/dev/null 2>&1 || true) &
  fi
fi

echo "[world-ui] Terraria World Creator UI"
echo "[world-ui] URL: http://$HOST:$PORT"
echo "[world-ui] Press Ctrl+C to stop."

exec env PYTHONUNBUFFERED=1 "$PYTHON_BIN" "$SERVER_PATH" --host "$HOST" --port "$PORT"
