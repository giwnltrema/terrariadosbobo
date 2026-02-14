#!/usr/bin/env bash
set -euo pipefail

HOST="127.0.0.1"
PORT="8787"
NO_BROWSER="${NO_BROWSER:-0}"

usage() {
  cat <<USAGE
Usage: scripts/world-creator-ui.sh [options]

Options:
  --host HOST       (default: 127.0.0.1)
  --port PORT       (default: 8787)
  --no-browser
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --no-browser)
      NO_BROWSER="1"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

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
