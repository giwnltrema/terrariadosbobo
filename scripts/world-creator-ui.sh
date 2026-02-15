#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="8787"
NO_BROWSER="${NO_BROWSER:-0}"
MODE="local"
K8S_NAMESPACE="terraria"
K8S_APP_NAME="world-creator-ui"
K8S_SERVICE_TYPE="NodePort"
K8S_NODE_PORT="30878"

usage() {
  cat <<USAGE
Usage: scripts/world-creator-ui.sh [options]

Options:
  --host HOST       (default: 127.0.0.1)
  --port PORT       (default: 8787)
  --no-browser
  --k8s             Deploy as Kubernetes Pod/Service instead of local process
  --k8s-delete      Remove Kubernetes resources created by --k8s
  --k8s-namespace N (default: terraria)
  --k8s-app-name N  (default: world-creator-ui)
  --k8s-node-port P (default: 30878)
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

delete_k8s_resources() {
  require_cmd kubectl
  kubectl -n "$K8S_NAMESPACE" delete service "$K8S_APP_NAME" --ignore-not-found >/dev/null
  kubectl -n "$K8S_NAMESPACE" delete deployment "$K8S_APP_NAME" --ignore-not-found >/dev/null
  kubectl -n "$K8S_NAMESPACE" delete rolebinding "${K8S_APP_NAME}-rb" --ignore-not-found >/dev/null
  kubectl -n "$K8S_NAMESPACE" delete role "${K8S_APP_NAME}-role" --ignore-not-found >/dev/null
  kubectl -n "$K8S_NAMESPACE" delete serviceaccount "${K8S_APP_NAME}-sa" --ignore-not-found >/dev/null
  kubectl -n "$K8S_NAMESPACE" delete configmap "${K8S_APP_NAME}-files" --ignore-not-found >/dev/null
  echo "[world-ui] Kubernetes resources removed from namespace '$K8S_NAMESPACE'."
}

deploy_k8s_resources() {
  require_cmd kubectl

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  SERVER_PATH="$REPO_ROOT/world-ui/server.py"
  INDEX_PATH="$REPO_ROOT/world-ui/static/index.html"
  CSS_PATH="$REPO_ROOT/world-ui/static/styles.css"
  JS_PATH="$REPO_ROOT/world-ui/static/app.js"
  UPLOAD_SCRIPT="$REPO_ROOT/scripts/upload-world.sh"

  for required in "$SERVER_PATH" "$INDEX_PATH" "$CSS_PATH" "$JS_PATH" "$UPLOAD_SCRIPT"; do
    if [[ ! -f "$required" ]]; then
      echo "Missing required file: $required" >&2
      exit 1
    fi
  done

  kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "$K8S_NAMESPACE" create configmap "${K8S_APP_NAME}-files" \
    --from-file=server.py="$SERVER_PATH" \
    --from-file=index.html="$INDEX_PATH" \
    --from-file=styles.css="$CSS_PATH" \
    --from-file=app.js="$JS_PATH" \
    --from-file=upload-world.sh="$UPLOAD_SCRIPT" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  CONFIG_VERSION="$(date +%s)"

  if [[ "$K8S_SERVICE_TYPE" == "NodePort" ]]; then
    SERVICE_PORT_BLOCK="      nodePort: $K8S_NODE_PORT"
  else
    SERVICE_PORT_BLOCK=""
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_APP_NAME}-sa
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${K8S_APP_NAME}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${K8S_APP_NAME}-role
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${K8S_APP_NAME}
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/exec", "pods/log"]
    verbs: ["get", "create"]
  - apiGroups: [""]
    resources: ["services", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "replicasets"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${K8S_APP_NAME}-rb
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${K8S_APP_NAME}
subjects:
  - kind: ServiceAccount
    name: ${K8S_APP_NAME}-sa
    namespace: ${K8S_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${K8S_APP_NAME}-role
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_APP_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${K8S_APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${K8S_APP_NAME}
  template:
    metadata:
      annotations:
        world-ui-config-version: "${CONFIG_VERSION}"
      labels:
        app: ${K8S_APP_NAME}
    spec:
      serviceAccountName: ${K8S_APP_NAME}-sa
      containers:
        - name: world-ui
          image: python:3.12-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: ${PORT}
              name: http
          command:
            - sh
            - -lc
            - |
              set -eu
              apk add --no-cache bash curl ca-certificates tar >/dev/null
              if ! command -v kubectl >/dev/null 2>&1; then
                KUBECTL_VERSION="\$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
                curl -fsSL "https://dl.k8s.io/release/\${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
                chmod +x /usr/local/bin/kubectl
              fi
              mkdir -p /workspace/world-ui/static /workspace/scripts
              cp /opt/world-ui-files/server.py /workspace/world-ui/server.py
              cp /opt/world-ui-files/index.html /workspace/world-ui/static/index.html
              cp /opt/world-ui-files/styles.css /workspace/world-ui/static/styles.css
              cp /opt/world-ui-files/app.js /workspace/world-ui/static/app.js
              cp /opt/world-ui-files/upload-world.sh /workspace/scripts/upload-world.sh
              sed -i 's/\r$//' /workspace/scripts/upload-world.sh
              chmod +x /workspace/scripts/upload-world.sh
              exec env PYTHONUNBUFFERED=1 WORLD_UI_NAMESPACE="${K8S_NAMESPACE}" python /workspace/world-ui/server.py --host 0.0.0.0 --port ${PORT}
          volumeMounts:
            - name: files
              mountPath: /opt/world-ui-files
              readOnly: true
      volumes:
        - name: files
          configMap:
            name: ${K8S_APP_NAME}-files
---
apiVersion: v1
kind: Service
metadata:
  name: ${K8S_APP_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${K8S_APP_NAME}
spec:
  selector:
    app: ${K8S_APP_NAME}
  type: ${K8S_SERVICE_TYPE}
  ports:
    - name: http
      port: ${PORT}
      targetPort: ${PORT}
${SERVICE_PORT_BLOCK}
EOF

  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/$K8S_APP_NAME" --timeout=300s

  echo "[world-ui] Terraria World Creator UI deployed in Kubernetes."

  if [[ "$K8S_SERVICE_TYPE" == "NodePort" ]]; then
    local node_port
    node_port="$(kubectl -n "$K8S_NAMESPACE" get service "$K8S_APP_NAME" -o jsonpath='{.spec.ports[0].nodePort}')"
    echo "[world-ui] URL: http://localhost:${node_port}"
  else
    echo "[world-ui] Service: ${K8S_APP_NAME}.${K8S_NAMESPACE}.svc.cluster.local:${PORT}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --no-browser)
      NO_BROWSER="1"; shift ;;
    --k8s)
      MODE="k8s"; shift ;;
    --k8s-delete)
      MODE="k8s-delete"; shift ;;
    --k8s-namespace)
      K8S_NAMESPACE="$2"; shift 2 ;;
    --k8s-app-name)
      K8S_APP_NAME="$2"; shift 2 ;;
    --k8s-node-port)
      K8S_NODE_PORT="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ "$MODE" == "k8s-delete" ]]; then
  delete_k8s_resources
  exit 0
fi

if [[ "$MODE" == "k8s" ]]; then
  deploy_k8s_resources
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_PATH="$REPO_ROOT/world-ui/server.py"

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
    # Empty title argument keeps cmd/start from treating URL as window title.
    (cmd.exe /c start "" "$URL" >/dev/null 2>&1 || true) &
  fi
fi

echo "[world-ui] Terraria World Creator UI"
echo "[world-ui] URL: http://$HOST:$PORT"
echo "[world-ui] Press Ctrl+C to stop."

exec env PYTHONUNBUFFERED=1 "$PYTHON_BIN" "$SERVER_PATH" --host "$HOST" --port "$PORT"


