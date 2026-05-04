#!/bin/bash
# install-hosting.sh — set up the iso-server web app + daily build timer.
# Idempotent: safe to re-run.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_FILE=/etc/iso-server.env

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' NC='\033[0m'
log()  { echo -e "${G}[+]${NC} $*"; }
info() { echo -e "${C}[i]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
die()  { echo -e "${R}[✗]${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"

# ─── 1. Packages ─────────────────────────────────────────────────────────────
log "Installing apt packages"
apt-get update -qq
apt-get install -y --no-install-recommends python3 python3-venv python3-pip jq curl rsync

# ─── 2. winbuild user ────────────────────────────────────────────────────────
if id winbuild &>/dev/null; then
    info "User 'winbuild' already exists"
else
    log "Creating user 'winbuild'"
    useradd --system --home /srv/iso-server --shell /usr/sbin/nologin winbuild
fi

# ─── 3. Directories ──────────────────────────────────────────────────────────
log "Creating directories"
install -d -o winbuild -g winbuild -m 755 /srv/iso /srv/iso-server /var/log/win11-builder

# ─── 4. App deploy ───────────────────────────────────────────────────────────
log "Deploying iso-server app to /srv/iso-server"
rsync -a --delete \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude 'tests' \
    --exclude 'pytest.ini' \
    "$REPO_DIR/iso-server/" /srv/iso-server/
chown -R winbuild:winbuild /srv/iso-server

# ─── 5. Virtualenv + deps ────────────────────────────────────────────────────
if [[ ! -d /srv/iso-server/.venv ]]; then
    log "Creating Python venv"
    sudo -u winbuild python3 -m venv /srv/iso-server/.venv
fi
log "Installing/updating Python dependencies"
sudo -u winbuild /srv/iso-server/.venv/bin/pip install -q --upgrade pip
sudo -u winbuild /srv/iso-server/.venv/bin/pip install -q -r /srv/iso-server/requirements.txt

# ─── 6. /etc/iso-server.env ──────────────────────────────────────────────────
#
# Six values are needed. They can come from three places, in priority order:
#   1. existing $ENV_FILE         (re-run preserves prior install)
#   2. environment variables      (export before running for non-interactive)
#   3. interactive prompt         (default for first-time install)
#
# Required env vars to skip prompts:
#   ISO_PASSWORD          shared password for the web download page
#   RESEND_API_KEY        from https://resend.com/api-keys
#   PUBLIC_URL            e.g. https://windows.example.com
#   RESEND_FROM           e.g. onboarding@resend.dev (or your verified Resend domain)
#   RESEND_TO             where build success/failure emails go
#
# ISO_COOKIE_SECRET is auto-generated and never prompted.

if [[ -f "$ENV_FILE" ]]; then
    info "$ENV_FILE already exists — keeping existing values"
    info "  (delete it to re-prompt or to use new env vars)"
else
    log "Generating $ENV_FILE"

    : "${ISO_PASSWORD:=}"
    : "${RESEND_API_KEY:=}"
    : "${PUBLIC_URL:=}"
    : "${RESEND_FROM:=onboarding@resend.dev}"
    : "${RESEND_TO:=}"

    if [[ -z "$ISO_PASSWORD" ]]; then
        read -rsp "Shared ISO download password: " ISO_PASSWORD; echo
        [[ -n "$ISO_PASSWORD" ]] || die "Password required"
    fi
    if [[ -z "$RESEND_API_KEY" ]]; then
        read -rsp "Resend API key (re_xxx): " RESEND_API_KEY; echo
        [[ -n "$RESEND_API_KEY" ]] || die "Resend API key required"
    fi
    if [[ -z "$PUBLIC_URL" ]]; then
        read -rp "Public URL (e.g. https://windows.example.com): " PUBLIC_URL
        [[ -n "$PUBLIC_URL" ]] || die "Public URL required"
    fi
    if [[ -z "$RESEND_TO" ]]; then
        read -rp "Email recipient for build notifications: " RESEND_TO
        [[ -n "$RESEND_TO" ]] || die "Recipient email required"
    fi

    COOKIE_SECRET=$(openssl rand -base64 32)
    cat > "$ENV_FILE" <<EOF
ISO_PASSWORD=$ISO_PASSWORD
ISO_COOKIE_SECRET=$COOKIE_SECRET
ISO_DIR=/srv/iso
PUBLIC_URL=$PUBLIC_URL
RESEND_API_KEY=$RESEND_API_KEY
RESEND_FROM=$RESEND_FROM
RESEND_TO=$RESEND_TO
EOF
    chown winbuild:winbuild "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "$ENV_FILE created (chmod 600)"
fi

# ─── 7. Daily wrapper ────────────────────────────────────────────────────────
log "Installing /usr/local/bin/win11-check.sh"
install -m 755 -o root -g root "$REPO_DIR/win11-check.sh" /usr/local/bin/win11-check.sh

# ─── 8. systemd units ────────────────────────────────────────────────────────
log "Installing systemd units"
install -m 644 -o root -g root "$REPO_DIR/systemd/iso-server.service"   /etc/systemd/system/
install -m 644 -o root -g root "$REPO_DIR/systemd/win11-check.service"  /etc/systemd/system/
install -m 644 -o root -g root "$REPO_DIR/systemd/win11-check.timer"    /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now iso-server.service
systemctl enable --now win11-check.timer

# ─── 9. Status ───────────────────────────────────────────────────────────────
log "All set. Status:"
systemctl is-active iso-server.service && info "iso-server.service: active"
systemctl is-active win11-check.timer  && info "win11-check.timer:  active"

# ─── 9b. Windows worker bootstrap ────────────────────────────────────────────
WIN_WORKER_HOST_DEFAULT="${WIN_WORKER_HOST:-192.0.2.7}"
log "Probing Windows worker at $WIN_WORKER_HOST_DEFAULT"
if ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
       "administrator@${WIN_WORKER_HOST_DEFAULT}" 'hostname' &>/dev/null; then
    log "Windows worker reachable; deploying Build-Iso.ps1"
    if ! "$REPO_DIR/windows-worker/deploy.sh"; then
        warn "Build-Iso.ps1 deploy failed (re-run windows-worker/deploy.sh manually)"
    fi
else
    warn "Windows worker (${WIN_WORKER_HOST_DEFAULT}) unreachable"
    warn "When the worker is online, run:  $REPO_DIR/windows-worker/deploy.sh"
fi

cat <<EOF

────────────────────────────────────────────────────────────────────
Web service:    http://127.0.0.1:8080  (cloudflared exposes publicly)
Public URL:     https://windows.example.com
Build timer:    fires daily; randomized within 2h
Manual check:   sudo systemctl start win11-check.service
Tail logs:      tail -F /var/log/win11-builder/check.log
────────────────────────────────────────────────────────────────────
EOF
