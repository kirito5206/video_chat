#!/usr/bin/env bash
#
# P2P Video Chat - Server-only launcher (Linux / macOS)
# Use this on the machine that hosts the signaling server.
#
# Usage:
#   ./start-server.sh [port]
#   ./start-server.sh 8765
#
set -euo pipefail

PORT="${1:-8765}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== P2P Video Chat - Signaling Server ==="

# Create venv if missing
if [ ! -d "$VENV_DIR" ]; then
  echo "[1/3] Creating virtual environment..."
  python3 -m venv "$VENV_DIR"
fi

echo "[2/3] Installing dependencies..."
"$VENV_DIR/bin/pip" install -q -r "$SERVER_DIR/requirements.txt"

echo "[3/3] Starting server on port $PORT..."
echo "      Connect clients to: ws://<this-host-ip>:$PORT"
"$VENV_DIR/bin/python" "$SERVER_DIR/signaling_server.py" --host 0.0.0.0 --port "$PORT"
