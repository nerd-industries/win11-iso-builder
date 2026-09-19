#!/usr/bin/env bash
# Patches an existing Win11 ISO: removes $WinPEDriver$ from boot.wim
# (kills WinPE auto-load of conflicting Intel storage drivers) while keeping
# \Drivers\ on the ISO root for manual "Load driver" use.
#
# Usage: patch-iso-remove-winpedriver.sh <iso-path>
# Idempotent — safe to re-run.
#
# Writes a new ISO to <iso>.patched then atomically replaces the original.
# This avoids xorriso's in-place "growing" mode (which appends orphan
# sessions and grows the file every run with no functional change).

set -euo pipefail
trap 'echo "[ERROR] line $LINENO exited $?" >&2' ERR

ISO="${1:?usage: $0 <iso-path>}"
[[ -f "$ISO" ]] || { echo "no such ISO: $ISO" >&2; exit 1; }
ISO="$(readlink -f "$ISO")"

command -v xorriso >/dev/null     || { echo "xorriso missing" >&2; exit 1; }
command -v wimlib-imagex >/dev/null || { echo "wimlib-imagex missing" >&2; exit 1; }

ISO_PARENT="$(dirname "$ISO")"
WORK="$(mktemp -d -p "$ISO_PARENT" .patch-iso.XXXXXX)"
MNT="$WORK/mnt"
NEW_ISO="${ISO}.patched"
mkdir -p "$MNT"
cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    rm -rf "$WORK"
    # If something blew up after writing NEW_ISO but before mv, leave it
    # for inspection — we only auto-clean on the success path below.
}
trap cleanup EXIT

echo "[1/6] Mounting ISO read-only to extract boot.wim..."
mount -o loop,ro "$ISO" "$MNT"
[[ -f "$MNT/sources/boot.wim" ]] || { echo "no /sources/boot.wim in ISO" >&2; exit 1; }
cp "$MNT/sources/boot.wim" "$WORK/boot.wim"
umount "$MNT"
chmod u+w "$WORK/boot.wim"
ls -lh "$WORK/boot.wim"

echo "[2/6] Stripping \$WinPEDriver\$ from every image..."
image_count=$(wimlib-imagex info "$WORK/boot.wim" \
              | awk -F: '/^Image Count:/ { gsub(/ /,"",$2); print $2 }')
echo "    boot.wim has $image_count image(s)"
for ((i=1; i<=image_count; i++)); do
    # --force makes delete a no-op if the path is absent, so we can run it
    # unconditionally on every image without checking first.
    echo "    image $i: delete --force --recursive /\$WinPEDriver\$"
    wimlib-imagex update "$WORK/boot.wim" "$i" \
        --command="delete --force --recursive /\$WinPEDriver\$"
done

echo "[3/6] Verifying \$WinPEDriver\$ is gone (grep dir listing)..."
for ((i=1; i<=image_count; i++)); do
    if wimlib-imagex dir "$WORK/boot.wim" "$i" 2>/dev/null | grep -q '^/\$WinPEDriver\$'; then
        echo "    image $i: still has \$WinPEDriver\$ — fail" >&2
        exit 1
    fi
    echo "    image $i: clean"
done
ls -lh "$WORK/boot.wim"

echo "[4/6] Building patched ISO at $NEW_ISO ..."
# -outdev different from -indev → full rewrite, no orphan-session growth.
rm -f "$NEW_ISO"
xorriso -boot_image any keep \
    -indev "$ISO" \
    -outdev "$NEW_ISO" \
    -map "$WORK/boot.wim" /sources/boot.wim \
    -commit 2>&1 | tail -15

echo "[5/6] Sanity-check patched ISO before swap..."
# Re-mount the patched ISO and re-verify boot.wim has no $WinPEDriver$.
mount -o loop,ro "$NEW_ISO" "$MNT"
cp "$MNT/sources/boot.wim" "$WORK/boot.wim.check"
umount "$MNT"
for ((i=1; i<=image_count; i++)); do
    if wimlib-imagex dir "$WORK/boot.wim.check" "$i" 2>/dev/null | grep -q '^/\$WinPEDriver\$'; then
        echo "    image $i in $NEW_ISO STILL has \$WinPEDriver\$ — aborting swap" >&2
        exit 1
    fi
done
echo "    patched ISO verified clean in all $image_count image(s)"

echo "[6/6] Atomic swap: $NEW_ISO → $ISO"
mv -f "$NEW_ISO" "$ISO"
ls -lh "$ISO"
echo "Done."
