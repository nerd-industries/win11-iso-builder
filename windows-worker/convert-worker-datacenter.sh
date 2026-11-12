#!/usr/bin/env bash
# Convert the Windows build worker VM from Server 2025 Standard *Evaluation*
# (Server Core) to fully licensed Datacenter, then activate it with your key.
#
# Run ON THE PROXMOX HOST (talks to the guest through the QEMU guest agent):
#   ./convert-worker-datacenter.sh                 # prompts for the key (blank = stock key, no activation)
#   ./convert-worker-datacenter.sh --stock         # switch edition only, no activation
#   ./convert-worker-datacenter.sh XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
#   ./convert-worker-datacenter.sh --check         # read-only status
#
# The edition switch uses Microsoft's public KMS client setup key; your real key
# (optional) is installed + activated afterwards with slmgr.
# Known quirk: DISM prints "Error: 1168" on Server Core eval. That's expected -
# the Datacenter package is staged and the reboot completes the switch.
#
# Safe to re-run: if the VM is already Datacenter it skips straight to the
# key/activation step. A ZFS snapshot is taken before anything changes.
#
# Env overrides: VMID=104  FORCE=1 (skip the "build in progress" check)
set -euo pipefail

VMID="${VMID:-104}"
SETUP_KEY="D764K-2NDRG-47T6Q-P8T8W-YP6DF"   # public Server 2025 Datacenter KMS client setup key
TARGET="ServerDatacenterCor"

c_ok=$'\e[32m'; c_err=$'\e[31m'; c_hdr=$'\e[1;34m'; c_off=$'\e[0m'
log()  { echo "${c_ok}[+]${c_off} $*"; }
hdr()  { echo; echo "${c_hdr}=== $* ===${c_off}"; }
die()  { echo "${c_err}[x]${c_off} $*" >&2; exit 1; }

# Run a PowerShell snippet in the guest; prints its output, returns its exit code.
gps() {
    local script="$1" timeout="${2:-120}" enc json rc
    script="\$ProgressPreference='SilentlyContinue'; $script"
    enc=$(printf '%s' "$script" | iconv -t UTF-16LE | base64 -w0)
    json=$(qm guest exec "$VMID" --timeout "$timeout" -- \
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$enc") || return 1
    jq -r '(.["out-data"] // "") + (.["err-data"] // "")' <<<"$json" | tr -d '\r' \
        | grep -vE '^#< CLIXML|^<Objs ' || true
    rc=$(jq -r '.exitcode // 1' <<<"$json")
    (( rc == 0 )) || return $(( rc > 255 ? 1 : rc ))
}

agent_up() { qm guest cmd "$VMID" ping >/dev/null 2>&1; }

wait_agent() {
    local i
    for i in $(seq 1 120); do agent_up && return 0; sleep 10; done
    die "Guest agent did not come back within 20 min - check the VM console"
}

build_procs() {
    gps '@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "Build-Iso|uup_download|convert-UUP|aria2c" }).Count' 60 | tr -dc '0-9'
}

current_edition() {
    gps '(dism /online /Get-CurrentEdition | Select-String "Current Edition") -replace ".*:\s*",""' 60 \
        | grep -v '^$' | tail -1 | tr -d ' '
}

# ---------------------------------------------------------------------------
command -v qm >/dev/null || die "Run this on the Proxmox host (qm not found)"
[[ "$(qm status "$VMID")" == "status: running" ]] || die "VM $VMID is not running (qm start $VMID first)"
agent_up || die "QEMU guest agent in VM $VMID is not responding"

if [[ "${1:-}" == "--check" ]]; then
    echo "Edition:        $(current_edition)"
    echo "Build procs:    $(build_procs) (0 = safe to convert)"
    gps 'cscript //nologo C:\Windows\System32\slmgr.vbs /xpr' 60
    exit 0
fi

KEY="${1:-}"
if [[ -z "$KEY" ]]; then
    read -rp "Datacenter product key to activate with (blank = switch with stock key only): " KEY
fi
KEY=$(tr '[:lower:]' '[:upper:]' <<<"$KEY" | tr -d ' ')
[[ "$KEY" == "--STOCK" || "$KEY" == "$SETUP_KEY" ]] && KEY=""
[[ -z "$KEY" || "$KEY" =~ ^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$ ]] || die "That doesn't look like a product key: $KEY"

hdr "Current state of VM $VMID"
ED=$(current_edition)
log "Edition: $ED"

if [[ "$ED" != "$TARGET" ]]; then
    [[ "$ED" == ServerStandardEval* ]] || die "Unexpected edition '$ED' - not touching it"

    hdr "Checking for a running ISO build"
    BUSY=$(build_procs)
    if [[ "${BUSY:-0}" -gt 0 && "${FORCE:-0}" != 1 ]]; then
        die "An ISO build is running on the worker ($BUSY processes). The edition switch reboots the VM and would kill it. Wait for the build email, or re-run with FORCE=1."
    fi
    log "No build running"

    hdr "Snapshot before changes"
    SNAP="pre-datacenter-$(date +%Y%m%d-%H%M)"
    qm snapshot "$VMID" "$SNAP" --description "Before eval -> Datacenter conversion" --vmstate 0
    log "Snapshot: $SNAP   (roll back with: qm rollback $VMID $SNAP)"

    hdr "Switching edition to $TARGET (takes a few minutes)"
    set +e
    gps "dism /online /Set-Edition:$TARGET /ProductKey:$SETUP_KEY /AcceptEula /NoRestart; if (\$LASTEXITCODE -eq 3010) { exit 0 } else { exit \$LASTEXITCODE }" 1800 \
        | grep -vE '^\s*$|^\[=*'
    rc=${PIPESTATUS[0]}
    set -e
    # 3010 (done, reboot needed) is mapped to 0 in the guest
    # On Server Core eval DISM reports Error 1168 ("Failed to copy edition license
    # file") because the Datacenter license tokens arrive in a package that only
    # installs on reboot. The edition package IS staged at that point - rebooting
    # completes the switch. So: any failure -> reboot and check the edition.
    if [[ "$rc" == 0 ]]; then log "DISM finished"; else log "DISM exit $rc (expected 1168 on Core eval) - rebooting to finish the staged switch"; fi

    hdr "Rebooting to complete the switch"
    qm reboot "$VMID" --timeout 900
    sleep 30
    wait_agent
    # servicing can add a second reboot; poll until the new edition shows up
    for i in $(seq 1 60); do
        ED=$(current_edition 2>/dev/null || true)
        [[ "$ED" == "$TARGET" ]] && break
        sleep 20; agent_up || wait_agent
    done
    [[ "$ED" == "$TARGET" ]] || die "Edition is still '$ED' after reboot - roll back with: qm rollback $VMID $SNAP"
    log "Edition is now $ED"
else
    log "Already $TARGET - skipping the edition switch"
fi

if [[ -z "$KEY" ]]; then
    hdr "Result"
    log "Edition is $(current_edition) with the stock setup key (not activated)."
    log "Unactivated Datacenter does NOT auto-shut down like the eval did."
    log "To activate later: $0 <your-key>"
    exit 0
fi

hdr "Installing your key and activating"
gps "cscript //nologo C:\\Windows\\System32\\slmgr.vbs /ipk $KEY" 120 || die "Key install failed (wrong key for Datacenter?)"
gps "cscript //nologo C:\\Windows\\System32\\slmgr.vbs /ato" 180 || die "Activation failed - output above. Key is installed; retry later with: slmgr /ato"

hdr "Result"
gps 'cscript //nologo C:\Windows\System32\slmgr.vbs /xpr' 60
gps 'cscript //nologo C:\Windows\System32\slmgr.vbs /dli' 60 | grep -iE 'Name|License Status' || true
echo
log "Done. Once you're happy, delete the snapshot:  qm listsnapshot $VMID ; qm delsnapshot $VMID <name>"
