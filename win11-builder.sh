#!/bin/bash
# win11-builder.sh
# Full pipeline:
#   - Fetch CU-integrated vanilla ISO from Windows worker (DISM-based)
#   - Verify install.wim build matches API claim
#   - Apply Rufus-style patches (Option 2a: LabConfig + HwReqChkVars + winsetup.dll)
#   - Replace appraiserres.dll (Option 6); add generic ei.cfg (Option 8)
#   - Inject Intel RST drivers ($WinPEDriver$ + ISO root \Drivers)
#   - Remove SetupPrep/SetupHost (force classic installer)
#   - Build final bootable ISO

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
# Kit lives next to the repo, NOT /tmp — systemd-tmpfiles wipes /tmp entries
# untouched for 10 days, which silently killed daily builds (June 2026).
readonly KIT_DIR="${KIT_DIR:-/root/win-build/kit/Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2}"
readonly WORK_DIR="/var/lib/win11-builder"
readonly UUP_LANG="${UUP_LANG:-en-us}"          # separate from $LANG (system locale)
readonly UUP_EDITION="${UUP_EDITION:-professional}"
readonly TARGET_PREFIX="${TARGET_PREFIX:-26300}"        # 26H2 = build family 26300; 26200 is 25H2; 26100 is 24H2; 22631 is 23H2
readonly TARGET_VERSION_NAME="${TARGET_VERSION_NAME:-26H2}"   # also matched against title to skip update-only packages
readonly UUP_API="https://api.uupdump.net"
readonly UUP_BASE="https://uupdump.net"

# Windows worker (provides CU-integrated vanilla ISOs via DISM)
readonly WIN_WORKER_USER="${WIN_WORKER_USER:-administrator}"
readonly WIN_WORKER_HOST="${WIN_WORKER_HOST:-192.0.2.7}"
readonly WIN_WORKER_SCRIPT='C:\Tools\Build-Iso.ps1'

# Globals set by pipeline stages (BASE_ISO and STAGING also accept env var overrides
# so caller can skip fetch and/or extract phases for dev iteration).
UUID=""
BUILD=""
BASE_ISO="${BASE_ISO:-}"
STAGING="${STAGING:-}"
FINAL_ISO=""

# ─── Colours ──────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m' C='\033[0;36m'
BO='\033[1m' NC='\033[0m'
log()  { echo -e "${G}[+]${NC} $*"; }
info() { echo -e "${C}[i]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
die()  { echo -e "${R}[✗]${NC} $*" >&2; exit 1; }
hdr()  { printf "\n${BO}${B}═══ %s ═══${NC}\n\n" "$*"; }

# ─── Dependency installation (Debian/apt) ────────────────────────────────────
install_deps() {
    hdr "Checking dependencies"
    local missing=()
    command -v chntpw        &>/dev/null || missing+=(chntpw)
    command -v wimlib-imagex &>/dev/null || missing+=(wimtools)
    command -v xorriso       &>/dev/null || missing+=(xorriso)
    command -v genisoimage   &>/dev/null || missing+=(genisoimage)
    command -v jq            &>/dev/null || missing+=(jq)
    command -v rsync         &>/dev/null || missing+=(rsync)
    command -v ssh           &>/dev/null || missing+=(openssh-client)
    python3 -c "import hivex" 2>/dev/null || missing+=(python3-hivex)
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "Installing missing packages: ${missing[*]}"
        sudo apt-get install -y --no-install-recommends "${missing[@]}"
    fi
    for cmd in chntpw wimlib-imagex xorriso genisoimage jq python3 ssh scp; do
        command -v "$cmd" &>/dev/null || die "Still missing: $cmd"
    done
    python3 -c "import hivex" 2>/dev/null || die "python-hivex not available (apt install python3-hivex)"
    log "All dependencies satisfied"
}

# ─── Kit files check ──────────────────────────────────────────────────────────
check_kit() {
    [[ -d "$KIT_DIR" ]]                                            || die "Kit dir missing: $KIT_DIR"
    [[ -f "$KIT_DIR/Files/appraiserres.dll" ]]                     || die "appraiserres.dll missing from kit"
    [[ -f "$KIT_DIR/Files/ei.cfg" ]]                               || die "ei.cfg missing from kit"
    [[ -f "$KIT_DIR/Files/24H2_Online_Upgrade_Enabler_Script.cmd" ]] || die "24H2 enabler script missing from kit"
    log "Kit files OK at $KIT_DIR"
}

# ─── Find latest 26100.x build ────────────────────────────────────────────────
find_latest_build() {
    hdr "Locating latest Windows 11 ${TARGET_VERSION_NAME} build"
    local resp
    resp=$(curl -s "${UUP_API}/listid.php?search=Windows+11&sortByDate=1") \
        || die "Failed to reach UUP Dump API"
    echo "$resp" | jq -e '.response.builds' &>/dev/null \
        || die "Unexpected API response — no .response.builds field. Raw: ${resp:0:200}"

    # Pick the HIGHEST-numbered amd64 entry (not the most recently posted: UUP
    # Dump can list a hotpatch build like 26300.9911 after the normal 26300.9974,
    # and hotpatch packages can't be integrated offline -> base ISO) that is BOTH
    # the right build family AND a full
    # OS image (title "Windows 11, version 25H2 (XXXXX.YYYY)"). Excludes
    # "Preview Update", "Cumulative Update", and "OOBE Update" packages, which
    # share the build number but are not bootable installers.
    local title_re="^Windows 11, version ${TARGET_VERSION_NAME} \\([0-9]+\\.[0-9]+\\)\$"
    local match
    match=$(echo "$resp" | jq -c \
        --arg px "${TARGET_PREFIX}." \
        --arg tre "$title_re" \
        '[.response.builds[]
          | select(.arch == "amd64"
                   and (.build | startswith($px))
                   and (.title | test($tre)))]
         | sort_by(.build | split(".") | map(tonumber)) | reverse | .[0]')

    [[ -n "$match" && "$match" != "null" ]] \
        || die "No full ${TARGET_VERSION_NAME} (${TARGET_PREFIX}.x) amd64 build found. Microsoft may have bumped the build family or UUP Dump may have changed its title format — check https://uupdump.net manually."

    UUID=$(echo "$match" | jq -r '.uuid')
    BUILD=$(echo "$match" | jq -r '.build')
    local title
    title=$(echo "$match" | jq -r '.title')

    log "Found: $title"
    log "       build $BUILD  UUID: $UUID"
}

# ─── Fetch CU-integrated vanilla ISO from the Windows worker ─────────────────
fetch_iso_from_windows() {
    hdr "Fetching CU-integrated ISO from Windows worker (${WIN_WORKER_USER}@${WIN_WORKER_HOST})"

    [[ -n "$UUID" && -n "$BUILD" ]] || die "fetch_iso_from_windows requires UUID and BUILD set (run find_latest_build first)"

    log "Asking Windows to build $BUILD ($UUID)"
    log "  This is the long step — UUP download + DISM CU integration + ISO build (~30-90 min)"

    # Build-Iso.ps1 prints status to stderr (forwarded to our terminal by ssh)
    # and emits exactly one line on stdout: the absolute Windows path to the ISO.
    local remote
    # Note: no quotes around the values. Windows OpenSSH's default shell is
    # PowerShell here, which interprets single-quoted args as PS string literals
    # and then re-quotes them when invoking the child powershell.exe — so quoted
    # values arrive at Build-Iso.ps1 with embedded single quotes. UUID, edition,
    # lang, and build all have no spaces, so unquoted is safe.
    # ServerAliveInterval=60 + CountMax=10 keeps the TCP alive through the
    # converter's tens-of-minutes silent stretches. Without these, idle-firewall
    # drops can sever the connection mid-build with no error logged on either
    # side (Build-Iso.ps1 finishes locally on the worker but its final stdout
    # is lost, and bash here returns non-zero — or worse, hangs).
    local ssh_opts=(-o ServerAliveInterval=60 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes)

    remote=$(ssh "${ssh_opts[@]}" "${WIN_WORKER_USER}@${WIN_WORKER_HOST}" \
        "powershell -ExecutionPolicy Bypass -File $WIN_WORKER_SCRIPT \
         -Uuid $UUID -Edition $UUP_EDITION -Lang $UUP_LANG -Build $BUILD") \
        || die "Windows worker SSH/script failed (worker offline? script crashed? See stderr above)"

    # Take the last non-empty line, strip CRLF Windows artifacts.
    remote=$(echo "$remote" | awk 'NF' | tail -1 | tr -d '\r')
    [[ "$remote" == *.iso ]] || die "Windows worker did not return an ISO path; got: '$remote'"

    local local_path="$WORK_DIR/$(basename "$remote")"
    log "SCPing $remote → $local_path"
    # OpenSSH accepts forward slashes for Windows paths; translate \ → /
    scp "${ssh_opts[@]}" "${WIN_WORKER_USER}@${WIN_WORKER_HOST}:${remote//\\//}" "$local_path" \
        || die "SCP from Windows worker failed"

    BASE_ISO="$local_path"
    log "Base ISO from worker: $BASE_ISO ($(du -sh "$BASE_ISO" | cut -f1))"
}

# ─── Extract base ISO to staging directory ────────────────────────────────────
extract_iso() {
    hdr "Extracting base ISO to staging area"
    local staging="$WORK_DIR/staging"
    rm -rf "$staging"
    mkdir -p "$staging"

    local mnt="$WORK_DIR/iso_mnt"
    mkdir -p "$mnt"
    sudo mount -o loop,ro "$BASE_ISO" "$mnt" || die "Cannot loop-mount $BASE_ISO"
    log "Copying ISO contents..."
    rsync -a "$mnt/" "$staging/"
    sudo umount "$mnt"

    chmod -R u+w "$staging"
    STAGING="$staging"
    log "Staging: $STAGING"
}

# ─── Verify the base ISO actually corresponds to the requested build ─────────
#
# We CANNOT rely on install.wim's Version metadata: even on Microsoft's official
# 25H2 install media, install.wim reports the BASE family (e.g. 10.0.26100)
# because 25H2 is delivered as an enablement package that flips at runtime, not
# baked into the offline WIM. The Windows worker (Build-Iso.ps1) already
# verified the produced ISO via filename match, and we name the SCPed file
# Win11-25H2-Pro-${BUILD}-vanilla.iso. So the most reliable signal here is
# checking $BASE_ISO's basename against $BUILD, plus a sanity check that
# install.wim is well-formed.
verify_build_number() {
    hdr "Verifying base ISO matches API claim ($BUILD)"
    local install_wim="$STAGING/sources/install.wim"
    [[ -f "$install_wim" ]] || die "install.wim not found at $install_wim"

    # 1. Filename check (the primary signal — the Windows worker named it after
    #    the actual integrated build, and we preserved the canonical name).
    if [[ -n "$BASE_ISO" ]]; then
        local iso_name
        iso_name=$(basename "$BASE_ISO")
        if [[ "$iso_name" != *"$BUILD"* ]]; then
            die "Base ISO filename '$iso_name' does not contain expected build '$BUILD'. The Windows worker may have produced the wrong build."
        fi
        log "Base ISO filename verified: '$iso_name' contains '$BUILD'"
    fi

    # 2. Sanity check that install.wim is a well-formed Pro image; log its
    #    reported metadata for diagnostics. Don't fail on it — the metadata
    #    cannot reflect post-enablement build numbers (Microsoft's design).
    local info
    info=$(wimlib-imagex info "$install_wim" 1 2>&1) \
        || die "wimlib-imagex info failed on install.wim"

    local major minor build spbuild edition
    major=$(echo "$info"   | awk -F: '/^Major Version:/      { gsub(/ /,"",$2); print $2 }')
    minor=$(echo "$info"   | awk -F: '/^Minor Version:/      { gsub(/ /,"",$2); print $2 }')
    build=$(echo "$info"   | awk -F: '/^Build:/              { gsub(/ /,"",$2); print $2 }')
    spbuild=$(echo "$info" | awk -F: '/^Service Pack Build:/ { gsub(/ /,"",$2); print $2 }')
    edition=$(echo "$info" | awk -F: '/^Edition ID:/         { sub(/^[ \t]*/,"",$2); print $2 }')

    [[ -n "$build" && -n "$spbuild" ]] \
        || die "Could not parse build numbers from wimlib-imagex info. Raw output:\n$info"

    local wim_version="${major:-?}.${minor:-?}.${build}.${spbuild}"
    info "  install.wim metadata: Version=$wim_version, Edition=${edition:-?}"
    info "  (install.wim metadata reports the base family — 25H2 enablement applies at runtime)"

    # Allowed build families. Override via env (space-separated) for one-off
    # builds against unusual versions, e.g. ALLOWED_BUILD_FAMILIES="22631 26100 26200"
    local allowed="${ALLOWED_BUILD_FAMILIES:-26100 26200 26300}"
    local family_ok=0
    for f in $allowed; do
        [[ "$build" == "$f" ]] && family_ok=1 && break
    done
    if [[ $family_ok -eq 0 ]]; then
        die "install.wim Build is $build — not in allowed families ($allowed). Override with ALLOWED_BUILD_FAMILIES env var if intentional."
    fi
    log "Build verification OK"
}

# ─── Option 2a: SYSTEM hive — LabConfig bypass ────────────────────────────────
patch_system_hive() {
    local hive="$1"
    python3 - "$hive" <<'PYEOF'
import hivex, struct, sys

h = hivex.Hivex(sys.argv[1], write=True)
root = h.root()

setup = h.node_get_child(root, "Setup")
if setup is None:
    setup = h.node_add_child(root, "Setup")

labconfig = h.node_get_child(setup, "LabConfig")
if labconfig is None:
    labconfig = h.node_add_child(setup, "LabConfig")

for name in ("BypassRAMCheck", "BypassTPMCheck", "BypassSecureBootCheck"):
    h.node_set_value(labconfig, {"key": name, "t": 4, "value": struct.pack("<I", 1)})

h.commit(None)
print("  SYSTEM hive: LabConfig bypass values written")
PYEOF
}

# ─── Option 2a: SOFTWARE hive — HwReqChkVars ─────────────────────────────────
patch_software_hive() {
    local hive="$1"
    python3 - "$hive" <<'PYEOF'
import hivex, sys

def get_or_create(h, parent, name):
    child = h.node_get_child(parent, name)
    if child is None:
        child = h.node_add_child(parent, name)
    return child

def delete_if_exists(h, parent, name):
    child = h.node_get_child(parent, name)
    if child is not None:
        h.node_delete_child(child)
        return True
    return False

h = hivex.Hivex(sys.argv[1], write=True)
root = h.root()

microsoft = get_or_create(h, root,      "Microsoft")
winnt     = get_or_create(h, microsoft, "Windows NT")
currver   = get_or_create(h, winnt,     "CurrentVersion")
acf       = get_or_create(h, currver,   "AppCompatFlags")

# Remove stale upgrade-blocker keys
for key in ("CompatMarkers", "Shared", "TargetVersionUpgradeExperienceIndicators"):
    if delete_if_exists(h, acf, key):
        print(f"  Deleted: {key}")

hwreqchk = get_or_create(h, acf, "HwReqChk")

# Exact values from Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2 Option 2a
strings = [
    "SQ_SSE2ProcessorSupport=TRUE",
    "SQ_SSE4_2ProcessorSupport=TRUE",
    "SQ_NXProcessorSupport=TRUE",
    "SQ_CompareExchange128=TRUE",
    "SQ_LahfSahfSupport=TRUE",
    "SQ_PrefetchWSupport=TRUE",
    "SQ_PopCntInstructionSupport=TRUE",
    "SQ_SecureBootCapable=TRUE",
    "SQ_SecureBootEnabled=TRUE",
    "SQ_TpmVersion=2",
    "SQ_RamMB=9999",
    "SQ_SystemDiskSizeMB=99999",
    "SQ_CpuCoreCount=9",
    "SQ_CpuModel=99",
    "SQ_CpuFamily=99",
    "SQ_CpuMhz=9999",
]

# REG_MULTI_SZ: each string null-terminated UTF-16LE, final extra NUL
data = b""
for s in strings:
    data += s.encode("utf-16-le") + b"\x00\x00"
data += b"\x00\x00"

h.node_set_value(hwreqchk, {"key": "HwReqChkVars", "t": 7, "value": data})
h.commit(None)
print(f"  SOFTWARE hive: HwReqChkVars set ({len(strings)} entries)")
PYEOF
}

# ─── Option 2a: winsetup.dll UTF-16LE patch ───────────────────────────────────
patch_winsetup_dll() {
    local dll="$1"
    python3 - "$dll" <<'PYEOF'
import sys

src = "Module_Init_HWRequirements".encode("utf-16-le")   # 52 bytes
dst = "Module_Init_GatherDiskInfo".encode("utf-16-le")   # 52 bytes — same length

with open(sys.argv[1], "rb") as f:
    data = bytearray(f.read())

count, pos = 0, 0
while True:
    idx = data.find(src, pos)
    if idx == -1:
        break
    data[idx:idx+len(src)] = dst
    count += 1
    pos = idx + len(dst)

if count == 0:
    print("  winsetup.dll: HWRequirements pattern not found — may already be patched")
else:
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    print(f"  winsetup.dll: patched {count} occurrence(s) — HWRequirements → GatherDiskInfo")
PYEOF
}

# ─── Apply all boot.wim modifications ────────────────────────────────────────
modify_boot_wim() {
    hdr "Modifying boot.wim"
    local boot_wim="$STAGING/sources/boot.wim"
    [[ -f "$boot_wim" ]] || die "boot.wim not found at $STAGING/sources/boot.wim"
    chmod u+w "$boot_wim"

    local tmp="$WORK_DIR/boot_wim_tmp"
    rm -rf "$tmp"; mkdir -p "$tmp"

    # ── Extract SYSTEM + SOFTWARE hives from index 2 ──────────────────────────
    log "Extracting registry hives from boot.wim index 2..."
    wimlib-imagex extract "$boot_wim" 2 \
        '\Windows\System32\config\SYSTEM' \
        '\Windows\System32\config\SOFTWARE' \
        --no-acls --no-attributes --dest-dir="$tmp"

    # ── Patch SYSTEM hive ─────────────────────────────────────────────────────
    log "Patching SYSTEM hive (LabConfig)..."
    chmod u+w "$tmp/SYSTEM"
    patch_system_hive "$tmp/SYSTEM"

    # ── Patch SOFTWARE hive ───────────────────────────────────────────────────
    log "Patching SOFTWARE hive (HwReqChkVars)..."
    chmod u+w "$tmp/SOFTWARE"
    patch_software_hive "$tmp/SOFTWARE"

    # ── Re-inject hives ───────────────────────────────────────────────────────
    log "Re-injecting hives into boot.wim..."
    wimlib-imagex update "$boot_wim" 2 \
        --command="add '$tmp/SYSTEM' '\Windows\System32\config\SYSTEM'"
    wimlib-imagex update "$boot_wim" 2 \
        --command="add '$tmp/SOFTWARE' '\Windows\System32\config\SOFTWARE'"

    # ── Extract + patch winsetup.dll ──────────────────────────────────────────
    log "Extracting winsetup.dll from boot.wim..."
    wimlib-imagex extract "$boot_wim" 2 \
        '\sources\winsetup.dll' \
        --no-acls --no-attributes --dest-dir="$tmp"
    chmod u+w "$tmp/winsetup.dll"

    log "Patching winsetup.dll..."
    patch_winsetup_dll "$tmp/winsetup.dll"

    wimlib-imagex update "$boot_wim" 2 \
        --command="add '$tmp/winsetup.dll' '\sources\winsetup.dll'"

    # ── Remove SetupPrep.exe + SetupHost.exe (classic installer enforcement) ──
    # NOTE: `wimlib-imagex delete` deletes ENTIRE IMAGES from a WIM. To delete
    # paths INSIDE an image, use `wimlib-imagex update --command="delete ..."`.
    # Earlier versions of this script used the wrong command and silently no-op'd.
    log "Removing SetupPrep.exe / SetupHost.exe from boot.wim index 2..."

    for wim_path in '/sources/SetupPrep.exe' '/sources/SetupHost.exe'; do
        if wimlib-imagex update "$boot_wim" 2 \
               --command="delete --force $wim_path" >/dev/null 2>&1; then
            log "  Deleted: $wim_path"
        else
            info "  Not found: $wim_path"
        fi
    done

    # Remove WinSxS component-store copies so they can't restore the binaries.
    local wim_listing
    wim_listing=$(wimlib-imagex dir "$boot_wim" 2 2>/dev/null)

    local -a base_dirs onecore_dirs
    mapfile -t base_dirs < <(echo "$wim_listing" | \
        grep -oiP '/Windows/WinSxS/amd64_microsoft-windows-setup360-media-base_[^/]+' | \
        sort -u)
    mapfile -t onecore_dirs < <(echo "$wim_listing" | \
        grep -oiP '/Windows/WinSxS/amd64_microsoft-windows-setup360-media-onecore_[^/]+' | \
        sort -u)

    for dir in "${base_dirs[@]}"; do
        for suffix in "/SetupPrep.exe" "/r/SetupPrep.exe"; do
            if wimlib-imagex update "$boot_wim" 2 \
                   --command="delete --force ${dir}${suffix}" >/dev/null 2>&1; then
                log "  Deleted: ${dir}${suffix}"
            else
                info "  Not found: ${dir}${suffix}"
            fi
        done
    done
    for dir in "${onecore_dirs[@]}"; do
        for suffix in "/SetupHost.exe" "/r/SetupHost.exe"; do
            if wimlib-imagex update "$boot_wim" 2 \
                   --command="delete --force ${dir}${suffix}" >/dev/null 2>&1; then
                log "  Deleted: ${dir}${suffix}"
            else
                info "  Not found: ${dir}${suffix}"
            fi
        done
    done

    log "boot.wim modifications complete"
}

# ─── Option 6: replace appraiserres.dll ───────────────────────────────────────
apply_option_6() {
    hdr "Option 6: replacing appraiserres.dll (Win10 15063)"
    local src_dll="$KIT_DIR/Files/appraiserres.dll"
    local dst_dir="$STAGING/sources"
    local dst_dll="$dst_dir/appraiserres.dll"

    [[ -f "$src_dll" ]] || die "Kit appraiserres.dll not found: $src_dll"
    [[ -d "$dst_dir" ]]  || die "sources/ not found in staging: $dst_dir"

    if [[ -f "$dst_dll" ]]; then
        mv "$dst_dll" "${dst_dll}.bak"
        log "Renamed original appraiserres.dll → appraiserres.dll.bak"
    fi
    cp "$src_dll" "$dst_dll"
    log "appraiserres.dll replaced"
}

# ─── Option 8: add generic ei.cfg ─────────────────────────────────────────────
apply_option_8() {
    hdr "Option 8: adding generic ei.cfg"
    local src_cfg="$KIT_DIR/Files/ei.cfg"
    local dst_dir="$STAGING/sources"

    [[ -f "$src_cfg" ]] || die "Kit ei.cfg not found: $src_cfg"

    if [[ -f "$dst_dir/ei.cfg" ]]; then
        mv "$dst_dir/ei.cfg" "$dst_dir/ei.cfg.ori"
        log "Renamed existing ei.cfg → ei.cfg.ori"
    fi
    cp "$src_cfg" "$dst_dir/ei.cfg"
    log "ei.cfg added"
}

# ─── Stage Intel RST drivers on ISO root (no $WinPEDriver$ auto-load) ─────────
# Auto-loading via $WinPEDriver$ caused "failed to load drivers" hangs on
# modern Intel chipsets because the bundle ships multiple driver generations
# with overlapping PCI HardwareIDs (8-9 and 10-11 AHCI/RAID, 10-11 and 12-15
# VMD). WinPE binds every .inf in $WinPEDriver$, and the conflict locks Setup
# for ~60-90s before it gives up. We now stage the full bundle on the ISO root
# at \Drivers\ only — the tech can "Load driver" from Setup if storage isn't
# detected. Two extra clicks vs. a guaranteed boot.
inject_rst_drivers() {
    hdr "Staging Intel RST drivers on ISO root"

    local rst_archive="$(dirname "$0")/RST_ALL_DRIVERS.tar.gz"
    [[ -f "$rst_archive" ]] || die "RST archive not found: $rst_archive"

    local rst_dir="$WORK_DIR/rst_drivers"
    if [[ ! -d "$rst_dir/RST_ALL_DRIVERS" ]]; then
        mkdir -p "$rst_dir"
        log "Extracting $rst_archive..."
        tar xzf "$rst_archive" -C "$rst_dir"
    else
        info "RST drivers already extracted at $rst_dir"
    fi

    # Strip any prior $WinPEDriver$ from boot.wim in case STAGING was reused.
    local boot_wim="$STAGING/sources/boot.wim"
    [[ -f "$boot_wim" ]] || die "boot.wim not found at $boot_wim"
    chmod u+w "$boot_wim"
    local image_count
    image_count=$(wimlib-imagex info "$boot_wim" 2>&1 \
                  | awk -F: '/^Image Count:/ { gsub(/ /,"",$2); print $2 }')
    [[ -n "$image_count" && "$image_count" -ge 1 ]] \
        || die "Could not determine image count of boot.wim"
    local i
    for ((i=1; i<=image_count; i++)); do
        wimlib-imagex update "$boot_wim" "$i" \
            --command="delete --force --recursive '\$WinPEDriver\$'" \
            >/dev/null 2>&1 || true
    done

    log "Copying RST_ALL_DRIVERS to ISO root as \\Drivers\\"
    rm -rf "$STAGING/Drivers"
    cp -r "$rst_dir/RST_ALL_DRIVERS" "$STAGING/Drivers"

    log "RST driver staging complete (manual load via Setup → Load driver)"
}

# ─── Copy 24H2 online upgrade enabler script ──────────────────────────────────
# --- Bake OOBE skip values into install.wim's SOFTWARE hive (no setup-time commands) ---
# On 26H2 any command in the specialize pass fails setup, so these live in the image.
bake_oobe_registry() {
    hdr "Baking OOBE registry values into install.wim"
    local wim="$STAGING/sources/install.wim" tmp n i
    [[ -f "$wim" ]] || die "install.wim missing: $wim"
    chmod u+w "$wim"
    tmp=$(mktemp -d)
    n=$(wimlib-imagex info "$wim" | awk -F: '/^Image Count:/{gsub(/ /,"",$2);print $2}')
    for ((i=1; i<=n; i++)); do
        rm -f "$tmp/SOFTWARE"
        wimlib-imagex extract "$wim" "$i" /Windows/System32/config/SOFTWARE --dest-dir="$tmp" --no-acls >/dev/null \
            || die "extract SOFTWARE from image $i failed"
        python3 - "$tmp/SOFTWARE" <<'PYH' || die "hive edit failed (image $i)"
import hivex, struct, sys
h = hivex.Hivex(sys.argv[1], write=True)
n = h.root()
for part in r"Microsoft\Windows\CurrentVersion\OOBE".split("\\"):
    c = h.node_get_child(n, part)
    n = c if c else h.node_add_child(n, part)
for name in ("BypassNRO", "HideOnlineAccountScreens", "HideWirelessSetupInOOBE"):
    h.node_set_value(n, {"key": name, "t": 4, "value": struct.pack("<I", 1)})
h.commit(None)
for name in ("BypassNRO", "HideOnlineAccountScreens", "HideWirelessSetupInOOBE"):
    v = h.node_get_value(n, name)
    assert struct.unpack("<I", h.value_value(v)[1])[0] == 1, name
PYH
        wimlib-imagex update "$wim" "$i" --command="add $tmp/SOFTWARE /Windows/System32/config/SOFTWARE" >/dev/null \
            || die "wimlib update image $i failed"
        log "  image $i: BypassNRO/HideOnlineAccountScreens/HideWirelessSetupInOOBE = 1"
        # SYSTEM hive: stop automatic BitLocker device encryption (24H2+ encrypts almost
        # any TPM+SecureBoot laptop during setup; with a local account the recovery key
        # is never backed up). BitLocker stays available for manual use.
        # Smart App Control off from first boot (otherwise it evaluates then can turn
        # itself On ~a day later and block unsigned apps), and S mode explicitly off.
        rm -f "$tmp/SYSTEM"
        wimlib-imagex extract "$wim" "$i" /Windows/System32/config/SYSTEM --dest-dir="$tmp" --no-acls >/dev/null \
            || die "extract SYSTEM from image $i failed"
        python3 - "$tmp/SYSTEM" <<'PYS' || die "SYSTEM hive edit failed (image $i)"
import hivex, struct, sys
h = hivex.Hivex(sys.argv[1], write=True)
def key(path):
    n = h.root()
    for part in path.split("\\"):
        c = h.node_get_child(n, part)
        n = c if c else h.node_add_child(n, part)
    return n
want = {
    r"ControlSet001\Control\BitLocker": {"PreventDeviceEncryption": 1},
    r"ControlSet001\Control\CI\Policy": {"VerifiedAndReputablePolicyState": 0, "SkuPolicyRequired": 0},
}
for path, vals in want.items():
    n = key(path)
    for name, v in vals.items():
        h.node_set_value(n, {"key": name, "t": 4, "value": struct.pack("<I", v)})
h.commit(None)
for path, vals in want.items():
    n = key(path)
    for name, v in vals.items():
        got = struct.unpack("<I", h.value_value(h.node_get_value(n, name))[1])[0]
        assert got == v, (path, name, got)
PYS
        wimlib-imagex update "$wim" "$i" --command="add $tmp/SYSTEM /Windows/System32/config/SYSTEM" >/dev/null \
            || die "wimlib update SYSTEM image $i failed"
        log "  image $i: PreventDeviceEncryption=1, SmartAppControl=off, SkuPolicyRequired=0"
    done
    rm -rf "$tmp"
}

copy_enabler_script() {
    hdr "Copying 24H2 Online Upgrade Enabler Script"
    local src="$KIT_DIR/Files/24H2_Online_Upgrade_Enabler_Script.cmd"
    [[ -f "$src" ]] || die "Enabler script not found: $src"
    cp "$src" "$STAGING/"
    log "24H2_Online_Upgrade_Enabler_Script.cmd copied to ISO root"
}

# ─── Split install.wim into .swm if it exceeds the ISO9660 4 GiB file limit ──
#
# Debian's xorriso 1.5.6 ships without UDF support, so we cannot embed >4 GiB
# files in the ISO. install.wim is typically 6-7 GiB on 25H2 builds, so we
# split it into install.swm + install2.swm + ... at 3500 MiB each. Microsoft's
# Setup reads .swm files transparently (this is the canonical solution for
# FAT32 USB sticks too).
# ─── Build final bootable ISO ─────────────────────────────────────────────────
build_iso() {
    hdr "Building bootable ISO (UDF, single install.wim)"

    # We build UDF via genisoimage so a >4 GiB install.wim ships as a SINGLE file
    # and still boots BIOS+UEFI -- the same filesystem Microsoft's retail media
    # uses. (Debian's xorriso 1.5.6 lacks UDF, which previously forced splitting
    # install.wim into .swm chunks on ISO9660. Customers want a single
    # install.wim, so we use genisoimage's -udf -allow-limited-size instead.)
    local wim="$STAGING/sources/install.wim"
    [[ -f "$wim" ]] || die "install.wim missing from staging: $wim"
    # Guard against a stale split left in a reused STAGING dir.
    rm -f "$STAGING"/sources/install*.swm
    log "install.wim: $(du -h "$wim" | cut -f1) (single file)"

    # autounattend.xml at the ISO root automates OOBE past the Microsoft-account
    # + network gate and lands on the local-account screen (26H2 removed the
    # Shift+F10 / bypassnro escape hatches). Setup reads it from the boot-media
    # root. Overridable/removable via AUTOUNATTEND env (set empty to skip).
    local unattend="${AUTOUNATTEND:-$(dirname "$0")/autounattend.xml}"
    if [[ -n "$unattend" && -f "$unattend" ]]; then
        cp "$unattend" "$STAGING/autounattend.xml"
        log "autounattend.xml staged at ISO root (OOBE automation)"
        # setclock.cmd: windowsPE pass moves a stale BIOS clock forward to the build date
        # (26H2 OOBE hangs on "Checking the connection to Microsoft" when the RTC is years behind).
        local bd; bd=$(date -u +%Y%m%d)
        sed -e "s/^set BUILDDATE=.*/set BUILDDATE=$bd/" \
            -e "s/^set BMM=.*/set BMM=${bd:4:2}\&set BDD=${bd:6:2}\&set BYY=${bd:0:4}/" \
            "$(dirname "$0")/setclock.cmd" > "$STAGING/setclock.cmd" || die "setclock.cmd missing"
        log "setclock.cmd staged (build date $bd)"
    else
        log "no autounattend.xml ($unattend) — OOBE left stock"
    fi

    # Volume label: WIN_11_26200_8328_X64_EN-US (max 32 chars)
    [[ -z "$BUILD" ]] && BUILD="unknown"
    local clean_build="${BUILD//./_}"
    local volid="WIN_11_${clean_build}_X64_EN-US"
    volid="${volid:0:32}"

    # Output filename is overridable via OUTPUT_ISO_NAME for one-off builds of
    # other families (e.g. 23H2). Default preserves the daily 25H2 naming.
    local output_iso="$WORK_DIR/${OUTPUT_ISO_NAME:-Win11-26H2-Pro-${BUILD}-RST-Rufus.iso}"

    # Verify boot files exist in staging
    local bios_boot="$STAGING/boot/etfsboot.com"
    local uefi_boot="$STAGING/efi/microsoft/boot/efisys.bin"
    [[ -f "$bios_boot" ]] || die "BIOS boot file missing: $bios_boot"
    [[ -f "$uefi_boot" ]] || die "UEFI boot file missing: $uefi_boot"

    log "Volume label: $volid"
    log "Output:       $output_iso"

    local gi_log="$WORK_DIR/genisoimage.log"
    # -udf + -allow-limited-size: UDF holds the true (>4 GiB) file size; Windows
    #   Setup reads via UDF, exactly like official media.
    # El Torito: BIOS (etfsboot.com, with boot-info-table) + UEFI (efisys.bin).
    genisoimage -quiet \
        -udf -allow-limited-size \
        -iso-level 3 -J -joliet-long \
        -V "$volid" \
        -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
        -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
        -o "$output_iso" \
        "$STAGING" \
        > "$gi_log" 2>&1 \
        || { tail -20 "$gi_log" >&2; die "genisoimage failed - see above"; }
    [[ -f "$output_iso" ]] || die "genisoimage exited OK but output ISO not found"

    # Verify: both boot records present, and the single install.wim reads at its
    # full byte size through UDF (catches a silent >4 GiB truncation).
    # NOTE: grep -c / ls-glob return non-zero on "no match", which under
    # `set -euo pipefail` would abort the script BEFORE the die messages fire.
    # Append `|| true` / use a nullglob array so the [[ ]] checks do the failing
    # with a real message instead of a silent set -e exit.
    local bios uefi
    bios=$(xorriso -indev "$output_iso" -report_el_torito plain 2>/dev/null | grep -c 'BIOS' || true)
    uefi=$(xorriso -indev "$output_iso" -report_el_torito plain 2>/dev/null | grep -c 'UEFI' || true)
    [[ "$bios" -ge 1 && "$uefi" -ge 1 ]] || die "boot records incomplete (BIOS=$bios UEFI=$uefi)"
    local exp_sz vmnt act_sz
    exp_sz=$(stat -c%s "$wim")
    vmnt="$WORK_DIR/verify_mnt"; mkdir -p "$vmnt"
    if mount -o loop,ro -t udf "$output_iso" "$vmnt" 2>/dev/null; then
        act_sz=$(stat -c%s "$vmnt/sources/install.wim" 2>/dev/null || echo 0)
        local swmfiles
        shopt -s nullglob
        swmfiles=("$vmnt"/sources/install*.swm)
        shopt -u nullglob
        umount "$vmnt"
        [[ ${#swmfiles[@]} -eq 0 ]] || die "ISO still contains .swm parts (${#swmfiles[@]})"
        [[ "$act_sz" == "$exp_sz" ]] || die "install.wim truncated in ISO (expected $exp_sz, got $act_sz)"
        log "Verified: single install.wim ($act_sz bytes), BIOS+UEFI boot, UDF"
    else
        log "WARN: could not UDF-mount output for verification (continuing)"
    fi
    rmdir "$vmnt" 2>/dev/null || true

    log "ISO created: $output_iso ($(du -sh "$output_iso" | cut -f1))"
    FINAL_ISO="$output_iso"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "\n${BO}${B}Windows 11 ${TARGET_VERSION_NAME} Pro ISO Builder${NC}"
    echo -e "${C}Kit: $KIT_DIR${NC}\n"

    # Allow re-running from a checkpoint by checking env vars
    # Usage: BASE_ISO=/path/to/base.iso ./win11-builder.sh  (skip download)
    # Usage: STAGING=/path/to/staging  ./win11-builder.sh   (skip extract too)

    install_deps
    check_kit
    mkdir -p "$WORK_DIR"

    if [[ -n "${STAGING:-}" ]]; then
        info "STAGING set — skipping fetch/extract: $STAGING"
        [[ -d "$STAGING" ]] || die "STAGING dir not found: $STAGING"
    elif [[ -n "${BASE_ISO:-}" ]]; then
        info "BASE_ISO set — skipping fetch: $BASE_ISO"
        [[ -f "$BASE_ISO" ]] || die "BASE_ISO not found: $BASE_ISO"
        extract_iso
    else
        find_latest_build
        fetch_iso_from_windows
        extract_iso
    fi

    # If BUILD wasn't set (STAGING/BASE_ISO branches), parse it from install.wim
    # so verify_build_number has something to compare against. In those branches
    # we trust the user — verification just records what the wim claims.
    if [[ -z "$BUILD" ]]; then
        local probed
        probed=$(wimlib-imagex info "$STAGING/sources/install.wim" 1 2>&1 \
                 | awk -F: '/^Build:/{b=$2} /^Service Pack Build:/{s=$2}
                            END{gsub(/ /,"",b);gsub(/ /,"",s);
                                if (b!="" && s!="") print b"."s}')
        [[ -n "$probed" ]] || die "Could not probe BUILD from install.wim — wimlib-imagex output may have changed format"
        BUILD="$probed"
        info "BUILD probed from install.wim: $BUILD"
    fi
    verify_build_number

    modify_boot_wim
    apply_option_6
    apply_option_8
    inject_rst_drivers
    copy_enabler_script
    bake_oobe_registry
    build_iso

    echo -e "\n${G}${BO}All done.${NC}"
    echo -e "  ISO:  ${BO}${FINAL_ISO}${NC}"
}

main "$@"
