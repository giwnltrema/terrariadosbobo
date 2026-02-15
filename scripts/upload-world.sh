#!/usr/bin/env bash
set -euo pipefail

WORLD_FILE=""
WORLD_NAME=""
NAMESPACE="terraria"
DEPLOYMENT="terraria-server"
PVC_NAME="terraria-config"
MANAGER_POD_NAME="world-manager"
MANAGER_IMAGE="ghcr.io/beardedio/terraria:latest"
AUTO_CREATE_IF_MISSING="true"
WORLD_SIZE="medium"
MAX_PLAYERS="8"
DIFFICULTY="classic"
SEED=""
SERVER_PORT="7777"
EXTRA_CREATE_ARGS=""

usage() {
  cat <<USAGE
Usage: scripts/upload-world.sh [options]

Options:
  --world-file PATH
  --world-name NAME.wld
  --namespace NAME                (default: terraria)
  --deployment NAME               (default: terraria-server)
  --pvc-name NAME                 (default: terraria-config)
  --manager-pod-name NAME         (default: world-manager)
  --manager-image IMAGE           (default: ghcr.io/beardedio/terraria:latest)
  --no-auto-create                (do not create world if missing)
  --world-size small|medium|large (default: medium)
  --max-players N                 (default: 8)
  --difficulty classic|expert|master|journey (default: classic)
  --seed VALUE
  --server-port N                 (default: 7777)
  --extra-create-args "..."      (raw args appended to TerrariaServer autocreate cmd)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --world-file)
      WORLD_FILE="$2"; shift 2 ;;
    --world-name)
      WORLD_NAME="$2"; shift 2 ;;
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    --deployment)
      DEPLOYMENT="$2"; shift 2 ;;
    --pvc-name)
      PVC_NAME="$2"; shift 2 ;;
    --manager-pod-name)
      MANAGER_POD_NAME="$2"; shift 2 ;;
    --manager-image)
      MANAGER_IMAGE="$2"; shift 2 ;;
    --no-auto-create)
      AUTO_CREATE_IF_MISSING="false"; shift ;;
    --world-size)
      WORLD_SIZE="$2"; shift 2 ;;
    --max-players)
      MAX_PLAYERS="$2"; shift 2 ;;
    --difficulty)
      DIFFICULTY="$2"; shift 2 ;;
    --seed)
      SEED="$2"; shift 2 ;;
    --server-port)
      SERVER_PORT="$2"; shift 2 ;;
    --extra-create-args)
      EXTRA_CREATE_ARGS="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Parametro desconhecido: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -n "$WORLD_FILE" && ! -f "$WORLD_FILE" ]]; then
  echo "Arquivo nao encontrado: $WORLD_FILE" >&2
  exit 1
fi

if [[ -n "$WORLD_FILE" ]]; then
  file_world_name="$(basename "$WORLD_FILE")"
  if [[ -n "$WORLD_NAME" && "$WORLD_NAME" != "$file_world_name" ]]; then
    echo "WorldName ($WORLD_NAME) difere do nome do arquivo enviado ($file_world_name)." >&2
    exit 1
  fi
  WORLD_NAME="$file_world_name"
fi

if [[ -z "$WORLD_NAME" ]]; then
  echo "Informe --world-name (ou --world-file)." >&2
  exit 1
fi

case "$WORLD_SIZE" in
  small) WORLD_SIZE_NUMBER=1 ;;
  medium) WORLD_SIZE_NUMBER=2 ;;
  large) WORLD_SIZE_NUMBER=3 ;;
  *) echo "world-size invalido: $WORLD_SIZE" >&2; exit 1 ;;
esac

case "$DIFFICULTY" in
  classic) DIFFICULTY_NUMBER=0 ;;
  expert) DIFFICULTY_NUMBER=1 ;;
  master) DIFFICULTY_NUMBER=2 ;;
  journey) DIFFICULTY_NUMBER=3 ;;
  *) echo "difficulty invalida: $DIFFICULTY" >&2; exit 1 ;;
esac

WORLD_BASE_NAME="${WORLD_NAME%.wld}"

echo "Escalando $DEPLOYMENT para 0 replicas para manipular o volume..."
kubectl scale "deployment/$DEPLOYMENT" -n "$NAMESPACE" --replicas=0 >/dev/null
kubectl rollout status "deployment/$DEPLOYMENT" -n "$NAMESPACE" --timeout=180s >/dev/null

echo "Subindo pod auxiliar '$MANAGER_POD_NAME' montando PVC '$PVC_NAME'..."
kubectl delete pod "$MANAGER_POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $MANAGER_POD_NAME
  namespace: $NAMESPACE
spec:
  restartPolicy: Never
  containers:
    - name: world-manager
      image: $MANAGER_IMAGE
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: terraria-config
          mountPath: /config
  volumes:
    - name: terraria-config
      persistentVolumeClaim:
        claimName: $PVC_NAME
EOF

kubectl wait --for=condition=Ready "pod/$MANAGER_POD_NAME" -n "$NAMESPACE" --timeout=180s >/dev/null

exists_output="$(kubectl exec -n "$NAMESPACE" "$MANAGER_POD_NAME" -- sh -lc "if [ -f '/config/$WORLD_NAME' ]; then echo exists; else echo missing; fi")"
world_exists="false"
if [[ "$exists_output" == "exists" ]]; then
  world_exists="true"
fi

if [[ -n "$WORLD_FILE" ]]; then
  echo "Copiando arquivo '$WORLD_NAME' para o PVC..."
  kubectl cp "$WORLD_FILE" "${NAMESPACE}/${MANAGER_POD_NAME}:/config/$WORLD_NAME" >/dev/null
  world_exists="true"
elif [[ "$world_exists" != "true" && "$AUTO_CREATE_IF_MISSING" == "true" ]]; then
  echo "Mundo '$WORLD_NAME' nao existe. Criando automaticamente (size=$WORLD_SIZE, difficulty=$DIFFICULTY, maxplayers=$MAX_PLAYERS)..."

  cat <<'EOS' | kubectl exec -i -n "$NAMESPACE" "$MANAGER_POD_NAME" -- sh -s -- "/config/$WORLD_NAME" "$WORLD_BASE_NAME" "$WORLD_SIZE_NUMBER" "$DIFFICULTY_NUMBER" "$MAX_PLAYERS" "$SERVER_PORT" "$SEED" "$EXTRA_CREATE_ARGS"
set -eu

WORLD_PATH="$1"
WORLD_NAME="$2"
WORLD_SIZE="$3"
WORLD_DIFFICULTY="$4"
MAX_PLAYERS="$5"
SERVER_PORT="$6"
WORLD_SEED="$7"
EXTRA_CREATE_ARGS="$8"

TERRARIA_BIN=""
for candidate in ./TerrariaServer /vanilla/TerrariaServer /tshock/TerrariaServer /TerrariaServer; do
  if [ -x "$candidate" ]; then
    TERRARIA_BIN="$candidate"
    break
  fi
done

if [ -z "$TERRARIA_BIN" ]; then
  TERRARIA_BIN="$(command -v TerrariaServer || true)"
fi

if [ -z "$TERRARIA_BIN" ]; then
  echo "TerrariaServer binary not found inside manager pod" >&2
  exit 1
fi

CMD="\"$TERRARIA_BIN\" -x64 -autocreate \"$WORLD_SIZE\" -world \"$WORLD_PATH\" -worldname \"$WORLD_NAME\" -difficulty \"$WORLD_DIFFICULTY\" -maxplayers \"$MAX_PLAYERS\" -port \"$SERVER_PORT\""

if [ -n "$WORLD_SEED" ]; then
  CMD="$CMD -seed \"$WORLD_SEED\""
fi

if [ -n "$EXTRA_CREATE_ARGS" ]; then
  CMD="$CMD $EXTRA_CREATE_ARGS"
fi

sh -c "$CMD >/tmp/worldgen.log 2>&1" &
pid=$!

i=0
while [ $i -lt 120 ]; do
  if [ -f "$WORLD_PATH" ]; then
    break
  fi
  i=$((i+1))
  sleep 2
done

kill "$pid" >/dev/null 2>&1 || true
wait "$pid" >/dev/null 2>&1 || true

if [ ! -f "$WORLD_PATH" ]; then
  echo "Falha ao criar mundo automaticamente" >&2
  cat /tmp/worldgen.log >&2 || true
  exit 1
fi
EOS

  world_exists="true"
fi

if [[ "$world_exists" != "true" ]]; then
  echo "Mundo '$WORLD_NAME' nao existe no PVC e auto-create foi desativado." >&2
  exit 1
fi

echo "Limpando pod auxiliar..."
kubectl delete pod "$MANAGER_POD_NAME" -n "$NAMESPACE" --ignore-not-found >/dev/null

echo "Configurando deployment $DEPLOYMENT para usar mundo '$WORLD_NAME'..."
kubectl set env "deployment/$DEPLOYMENT" -n "$NAMESPACE" "world=$WORLD_NAME" "worldpath=/config" >/dev/null

echo "Subindo deployment $DEPLOYMENT com mundo '$WORLD_NAME'..."
kubectl scale "deployment/$DEPLOYMENT" -n "$NAMESPACE" --replicas=1 >/dev/null

if ! kubectl rollout status "deployment/$DEPLOYMENT" -n "$NAMESPACE" --timeout=300s; then
  echo "Rollout falhou para deployment/$DEPLOYMENT. Diagnostico rapido:" >&2
  kubectl get pods -n "$NAMESPACE" -l app=terraria-server -o wide >&2 || true
  kubectl logs "deployment/$DEPLOYMENT" -n "$NAMESPACE" --tail=120 >&2 || true
  exit 1
fi

echo "Mundo pronto: $WORLD_NAME"
