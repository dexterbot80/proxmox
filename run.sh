#!/usr/bin/env bash
set -euo pipefail

# === CONFIG: schimbă doar REPO_RAW_BASE după ce urci repo-ul ===
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/USER/REPO/main}"
SCRIPT_NAME="create-openhabian-vm.sh"
TMP="/tmp/${SCRIPT_NAME}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "Lipsește comanda: $1"; exit 1; }; }

echo "[run.sh] Verific dependențe..."
require bash
require curl
require qm
require pvesm
require wget
require sha256sum
require python3
require base64

echo "[run.sh] Descarc ${SCRIPT_NAME}..."
curl -fsSL "${REPO_RAW_BASE}/${SCRIPT_NAME}" -o "$TMP"
chmod +x "$TMP"

echo "[run.sh] Rulez ${SCRIPT_NAME}..."
exec "$TMP"
