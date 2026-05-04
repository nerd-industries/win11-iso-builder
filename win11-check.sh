#!/bin/bash
# Daily Windows 11 25H2 build check.
# - Polls UUP Dump for the latest 25H2 (26200.x) full image
# - If newer than what's in /srv/iso/, runs win11-builder.sh
# - On success: moves ISO to /srv/iso/, prunes to last 3, emails success
# - On failure: emails failure with last 30 lines of log

set -uo pipefail   # NOT -e: we want to control failure paths ourselves

ENV_FILE=/etc/iso-server.env
ISO_DIR=/srv/iso
LOG_DIR=/var/log/win11-builder
LOG=$LOG_DIR/check.log
BUILDER="${BUILDER:-/root/win-build/win11-builder.sh}"
WORK_DIR=/var/lib/win11-builder

UUP_API="https://api.uupdump.net"
TARGET_PREFIX="26200"
TARGET_VERSION_NAME="25H2"

# ─── Bootstrap ───────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$ISO_DIR"
exec >>"$LOG" 2>&1

# shellcheck disable=SC1090
source "$ENV_FILE"   # ISO_PASSWORD, RESEND_API_KEY, RESEND_FROM, RESEND_TO, PUBLIC_URL
: "${RESEND_API_KEY:?missing in $ENV_FILE}"
: "${RESEND_FROM:?missing in $ENV_FILE}"
: "${RESEND_TO:?missing in $ENV_FILE}"
: "${PUBLIC_URL:?missing in $ENV_FILE}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) $*"; }

# ─── Email helpers ───────────────────────────────────────────────────────────
send_email() {
    local subject="$1" body="$2"
    local payload
    payload=$(jq -n \
        --arg from "$RESEND_FROM" \
        --arg to "$RESEND_TO" \
        --arg subject "$subject" \
        --arg text "$body" \
        '{from:$from, to:[$to], subject:$subject, text:$text}')
    local response
    response=$(curl -sS -X POST https://api.resend.com/emails \
        -H "Authorization: Bearer $RESEND_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
            log "Resend POST failed: $response"
            return 1
        }
    if echo "$response" | grep -q '"id"'; then
        log "Email sent: $subject"
    else
        log "Email API error: $response"
        return 1
    fi
}

send_success_email() {
    local build="$1" iso_name="$2"
    local body
    body=$(cat <<EOF
A new Windows 11 25H2 ISO is built and ready.

Build:    $build
Date:     $(date -u +%Y-%m-%d)
Download: $PUBLIC_URL/iso/$iso_name

Log in with your shared password at $PUBLIC_URL/login
EOF
)
    send_email "Windows 11 25H2 build $build ready" "$body"
}

send_failure_email() {
    local build="$1"
    local body
    body=$(cat <<EOF
Build attempt for $build FAILED.

Last 30 lines of log:
$(tail -n 30 "$LOG" 2>/dev/null || echo "(log unavailable)")

Full log: $LOG
EOF
)
    send_email "Windows 11 25H2 build $build FAILED" "$body"
}

# ─── 1. API check ────────────────────────────────────────────────────────────
log "===== Daily check start ====="
api_resp=$(curl -fsS "${UUP_API}/listid.php?search=Windows+11&sortByDate=1") || {
    log "UUP Dump API unreachable — skipping this run"
    exit 0
}

api_build=$(echo "$api_resp" | jq -r --arg px "${TARGET_PREFIX}." --arg name "$TARGET_VERSION_NAME" '
    [.response.builds[]
     | select(.arch == "amd64"
              and (.build | startswith($px))
              and (.title | test("^Windows 11, version " + $name + " \\([0-9]+\\.[0-9]+\\)$")))]
    | sort_by(.created) | reverse | .[0] | .build // empty')

if [[ -z "$api_build" ]]; then
    log "API returned no matching $TARGET_VERSION_NAME builds — skipping"
    exit 0
fi
log "Latest on UUP Dump: $api_build"

# ─── 2. Compare to local ─────────────────────────────────────────────────────
local_build=$(ls "$ISO_DIR"/Win11-25H2-Pro-*-RST-Rufus.iso 2>/dev/null \
              | sed -E 's/.*Pro-([0-9.]+)-RST-Rufus.*/\1/' \
              | sort -V | tail -1)

if [[ "$api_build" == "$local_build" ]]; then
    log "Up to date ($local_build) — nothing to do"
    exit 0
fi

log "New build available: $api_build (local: ${local_build:-none})"

# ─── 3. Build ────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"
log "Running $BUILDER ..."
if ! "$BUILDER"; then
    log "Builder exited non-zero"
    send_failure_email "$api_build"
    exit 1
fi

# ─── 4. Deploy + prune ───────────────────────────────────────────────────────
iso_name="Win11-25H2-Pro-${api_build}-RST-Rufus.iso"
src="$WORK_DIR/$iso_name"
if [[ ! -f "$src" ]]; then
    log "Builder claimed success but $src missing"
    send_failure_email "$api_build"
    exit 1
fi

mv "$src" "$ISO_DIR/$iso_name"
log "Deployed: $ISO_DIR/$iso_name"

# Prune to last 3 by mtime
mapfile -t old < <(ls -1t "$ISO_DIR"/Win11-25H2-Pro-*-RST-Rufus.iso 2>/dev/null | tail -n +4)
for f in "${old[@]}"; do
    rm -f "$f" && log "Pruned: $f"
done

# ─── 5. Email success ────────────────────────────────────────────────────────
send_success_email "$api_build" "$iso_name"
log "===== Daily check done ====="
exit 0
