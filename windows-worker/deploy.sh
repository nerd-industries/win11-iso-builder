#!/bin/bash
# deploy.sh — push Build-Iso.ps1 to the Windows worker.
# Idempotent: safe to re-run. Reads WIN_WORKER_USER/WIN_WORKER_HOST from env if set.

set -euo pipefail

WIN_WORKER_USER="${WIN_WORKER_USER:-administrator}"
WIN_WORKER_HOST="${WIN_WORKER_HOST:-192.0.2.7}"

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$REPO_DIR/Build-Iso.ps1"
DST_PATH="C:/Tools/Build-Iso.ps1"

[[ -f "$SRC" ]] || { echo "Missing: $SRC" >&2; exit 1; }

# Ensure C:\Tools exists on worker
ssh "${WIN_WORKER_USER}@${WIN_WORKER_HOST}" \
    'powershell -c "New-Item -ItemType Directory -Force -Path C:\Tools | Out-Null"'

# Push
scp "$SRC" "${WIN_WORKER_USER}@${WIN_WORKER_HOST}:${DST_PATH}"

# Confirm landed
ssh "${WIN_WORKER_USER}@${WIN_WORKER_HOST}" \
    "powershell -c \"if (Test-Path '$DST_PATH') { Write-Host 'OK: ' (Get-Item '$DST_PATH').Length 'bytes' } else { exit 1 }\""

echo "Deployed $SRC -> ${WIN_WORKER_USER}@${WIN_WORKER_HOST}:${DST_PATH}"
