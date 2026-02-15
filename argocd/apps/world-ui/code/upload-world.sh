#!/usr/bin/env bash
set -euo pipefail

WORLD_FILE=""
WORLD_NAME=""
NAMESPACE="terraria"
DEPLOYMENT="terraria-server"
PVC_NAME="terraria-config"
MANAGER_POD_NAME="world-manager"
MANAGER_IMAGE="ghcr.io/beardedio/terraria:tshock-latest"
AUTO_CREATE_IF_MISSING="true"
WORLD_SIZE="medium"
MAX_PLAYERS="8"
DIFFICULTY="classic"
SEED=""
SERVER_PORT="7777"
EXTRA_CREATE_ARGS=""
WORLD_CREATE_TIMEOUT_SECONDS="900"

ORIGINAL_REPLICAS="1"
SCALED_BACK="0"

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
  --manager-image IMAGE           (default: ghcr.io/beardedio/terraria:tshock-latest)
  --no-auto-create                (do not create world if missing)
  --world-size small|medium|large (default: medium)
  --max-players N                 (default: 8)
  --difficulty classic|expert|master|journey (default: classic)
  --seed VALUE
  --server-port N                 (default: 7777)
  --extra-create-args "..."      (raw args appended to world creation cmd)
  --world-create-timeout N        (seconds, default: 900)
USAGE
}

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$MANAGER_POD_NAME" --ignore-not-found >/dev/null 2>&1 || true

  if [[ "$SCALED_BACK" != "1" ]]; then
    kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas="$ORIGINAL_REPLICAS" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

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
    --world-create-timeout)
      WORLD_CREATE_TIMEOUT_SECONDS="$2"; shift 2 ;;
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

ORIGINAL_REPLICAS="$(kubectl -n "$NAMESPACE" get "deployment/$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
if [[ -z "$ORIGINAL_REPLICAS" ]]; then
  ORIGINAL_REPLICAS="1"
fi

echo "Escalando $DEPLOYMENT para 0 replicas para manipular o volume..."
kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas=0 >/dev/null
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=180s >/dev/null

echo "Subindo pod auxiliar '$MANAGER_POD_NAME' montando PVC '$PVC_NAME'..."
kubectl -n "$NAMESPACE" delete pod "$MANAGER_POD_NAME" --ignore-not-found >/dev/null

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

kubectl -n "$NAMESPACE" wait --for=condition=Ready "pod/$MANAGER_POD_NAME" --timeout=180s >/dev/null

exists_output="$(kubectl -n "$NAMESPACE" exec "$MANAGER_POD_NAME" -- sh -lc "if [ -f '/config/$WORLD_NAME' ]; then echo exists; else echo missing; fi")"
world_exists="false"
if [[ "$exists_output" == "exists" ]]; then
  world_exists="true"
fi

if [[ -n "$WORLD_FILE" ]]; then
  echo "Copiando arquivo '$WORLD_NAME' para o PVC..."
  kubectl -n "$NAMESPACE" cp "$WORLD_FILE" "$MANAGER_POD_NAME:/config/$WORLD_NAME" >/dev/null
  world_exists="true"
elif [[ "$world_exists" != "true" && "$AUTO_CREATE_IF_MISSING" == "true" ]]; then
  echo "Mundo '$WORLD_NAME' nao existe. Criando automaticamente (size=$WORLD_SIZE, difficulty=$DIFFICULTY, maxplayers=$MAX_PLAYERS)..."

  cat <<'EOS' | kubectl exec -i -n "$NAMESPACE" "$MANAGER_POD_NAME" -- sh -s -- "/config/$WORLD_NAME" "$WORLD_BASE_NAME" "$WORLD_SIZE_NUMBER" "$DIFFICULTY_NUMBER" "$MAX_PLAYERS" "$SERVER_PORT" "$SEED" "$EXTRA_CREATE_ARGS" "$WORLD_CREATE_TIMEOUT_SECONDS"
set -eu

WORLD_PATH="$1"
WORLD_NAME="$2"
WORLD_SIZE="$3"
WORLD_DIFFICULTY="$4"
MAX_PLAYERS="$5"
SERVER_PORT="$6"
WORLD_SEED="$7"
EXTRA_CREATE_ARGS="$8"
CREATE_TIMEOUT_SECONDS="$9"

resolve_bin() {
  if [ -x /tshock/TShock.Server ]; then
    echo "/tshock/TShock.Server"
    return
  fi
  if [ -x /tshock/TerrariaServer ]; then
    echo "/tshock/TerrariaServer"
    return
  fi
  if command -v TShock.Server >/dev/null 2>&1; then
    command -v TShock.Server
    return
  fi
  if command -v TerrariaServer >/dev/null 2>&1; then
    command -v TerrariaServer
    return
  fi
  if [ -x ./TerrariaServer ]; then
    echo "./TerrariaServer"
    return
  fi

  echo "Nenhum binario de servidor encontrado para autocreate." >&2
  return 1
}

SERVER_BIN="$(resolve_bin)"
CMD="$SERVER_BIN -autocreate \"$WORLD_SIZE\" -world \"$WORLD_PATH\" -worldname \"$WORLD_NAME\" -difficulty \"$WORLD_DIFFICULTY\" -maxplayers \"$MAX_PLAYERS\" -port \"$SERVER_PORT\""

if [ -n "$WORLD_SEED" ]; then
  CMD="$CMD -seed \"$WORLD_SEED\""
fi

if [ -n "$EXTRA_CREATE_ARGS" ]; then
  CMD="$CMD $EXTRA_CREATE_ARGS"
fi

rm -f "$WORLD_PATH"
sh -c "$CMD >/tmp/worldgen.log 2>&1" &
pid=$!

elapsed=0
while [ "$elapsed" -lt "$CREATE_TIMEOUT_SECONDS" ]; do
  if [ -s "$WORLD_PATH" ]; then
    break
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi

  sleep 2
  elapsed=$((elapsed+2))
done

if [ -s "$WORLD_PATH" ]; then
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  exit 0
fi

if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" >/dev/null 2>&1 || true
fi
wait "$pid" >/dev/null 2>&1 || true

echo "Falha ao criar mundo automaticamente" >&2
echo "--- /tmp/worldgen.log ---" >&2
cat /tmp/worldgen.log >&2 || true
exit 1
EOS

  world_exists="true"
fi

if [[ "$world_exists" != "true" ]]; then
  echo "Mundo '$WORLD_NAME' nao existe no PVC e auto-create foi desativado." >&2
  exit 1
fi

echo "Configurando deployment $DEPLOYMENT para usar mundo '$WORLD_NAME'..."
kubectl -n "$NAMESPACE" set env "deployment/$DEPLOYMENT" "world=$WORLD_NAME" "worldpath=/config" >/dev/null

echo "Subindo deployment $DEPLOYMENT com mundo '$WORLD_NAME'..."
kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas=1 >/dev/null

if ! kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=300s; then
  echo "Rollout falhou para deployment/$DEPLOYMENT. Diagnostico rapido:" >&2
  kubectl -n "$NAMESPACE" get pods -l app=terraria-server -o wide >&2 || true
  kubectl -n "$NAMESPACE" logs "deployment/$DEPLOYMENT" --tail=120 >&2 || true
  exit 1
fi

SCALED_BACK="1"
echo "Mundo pronto: $WORLD_NAME"
