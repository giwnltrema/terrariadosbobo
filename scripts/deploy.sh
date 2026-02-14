#!/usr/bin/env bash
set -euo pipefail

TERRAFORM_DIR="terraform"
KUBE_CONTEXT="docker-desktop"
WORLD_FILE=""
WORLD_NAME=""
SKIP_WORLD_ENSURE="false"
WORLD_SIZE="medium"
MAX_PLAYERS="8"
DIFFICULTY="classic"
SEED=""
SERVER_PORT="7777"
EXTRA_CREATE_ARGS=""

usage() {
  cat <<USAGE
Usage: scripts/deploy.sh [options]

Options:
  --terraform-dir PATH            (default: terraform)
  --kube-context NAME             (default: docker-desktop)
  --world-file PATH
  --world-name NAME.wld
  --skip-world-ensure
  --world-size small|medium|large
  --max-players N
  --difficulty classic|expert|master|journey
  --seed VALUE
  --server-port N
  --extra-create-args "..."
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terraform-dir)
      TERRAFORM_DIR="$2"; shift 2 ;;
    --kube-context)
      KUBE_CONTEXT="$2"; shift 2 ;;
    --world-file)
      WORLD_FILE="$2"; shift 2 ;;
    --world-name)
      WORLD_NAME="$2"; shift 2 ;;
    --skip-world-ensure)
      SKIP_WORLD_ENSURE="true"; shift ;;
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

if ! command -v terraform >/dev/null 2>&1; then
  echo "Terraform nao encontrado no PATH." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl nao encontrado no PATH." >&2
  exit 1
fi

if [[ ! -d "$TERRAFORM_DIR" ]]; then
  echo "Diretorio Terraform nao encontrado: $TERRAFORM_DIR" >&2
  exit 1
fi

current_context="$(kubectl config current-context 2>/dev/null || true)"
if [[ -z "$current_context" ]]; then
  echo "Nao foi possivel ler o contexto atual do kubectl." >&2
  exit 1
fi

if [[ "$current_context" != "$KUBE_CONTEXT" ]]; then
  echo "[0/6] Ajustando contexto para $KUBE_CONTEXT"
  kubectl config use-context "$KUBE_CONTEXT" >/dev/null
fi

echo "[0/6] Validando conectividade do cluster"
kubectl cluster-info >/dev/null
kubectl get nodes >/dev/null

echo "[1/6] terraform init"
terraform -chdir="$TERRAFORM_DIR" init

echo "[2/6] terraform validate"
terraform -chdir="$TERRAFORM_DIR" validate

if ! kubectl get crd probes.monitoring.coreos.com >/dev/null 2>&1; then
  echo "[3/6] Bootstrap do kube-prometheus-stack (CRDs)"
  terraform -chdir="$TERRAFORM_DIR" apply -target=helm_release.kube_prometheus_stack -auto-approve
else
  echo "[3/6] CRDs de monitoring ja existem, pulando bootstrap"
fi

echo "[4/6] terraform apply"
terraform -chdir="$TERRAFORM_DIR" apply -auto-approve

if [[ "$SKIP_WORLD_ENSURE" != "true" ]]; then
  resolved_world_name="$WORLD_NAME"

  if [[ -z "$resolved_world_name" && -f "$TERRAFORM_DIR/terraform.tfvars" ]]; then
    resolved_world_name="$(grep -E '^\s*world_file\s*=\s*".+"\s*$' "$TERRAFORM_DIR/terraform.tfvars" | head -n1 | sed -E 's/^\s*world_file\s*=\s*"(.+)"\s*$/\1/')"
  fi

  if [[ -z "$resolved_world_name" && -n "$WORLD_FILE" ]]; then
    resolved_world_name="$(basename "$WORLD_FILE")"
  fi

  if [[ -z "$resolved_world_name" ]]; then
    resolved_world_name="test.wld"
  fi

  echo "[5/6] Garantindo mundo '$resolved_world_name' no PVC"

  args=(
    "--world-name" "$resolved_world_name"
    "--world-size" "$WORLD_SIZE"
    "--max-players" "$MAX_PLAYERS"
    "--difficulty" "$DIFFICULTY"
    "--seed" "$SEED"
    "--server-port" "$SERVER_PORT"
    "--extra-create-args" "$EXTRA_CREATE_ARGS"
  )

  if [[ -n "$WORLD_FILE" ]]; then
    args+=("--world-file" "$WORLD_FILE")
  fi

  bash "$(dirname "$0")/upload-world.sh" "${args[@]}"
else
  echo "[5/6] SkipWorldEnsure ativo, pulando gerenciamento de mundo"
fi

echo "[6/6] Estado dos recursos"
kubectl get pods -A
kubectl get svc -A