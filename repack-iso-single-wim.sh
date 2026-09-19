#!/usr/bin/env bash
# Repack a Windows ISO so sources\install*.swm becomes a single sources\install.wim.
# Rebuilds as a UDF ISO (via genisoimage) so the >4 GiB WIM fits and still boots
# BIOS+UEFI — the same filesystem Microsoft's retail media uses. Idempotent:
# an ISO that already has a single install.wim is rebuilt UDF unchanged.
#
# Usage: repack-iso-single-wim.sh <iso-path>
# Swaps in place after verifying the rebuilt ISO.
set -euo pipefail
trap 'echo "[ERROR] line $LINENO exited $?" >&2' ERR

ISO="${1:?usage: $0 <iso-path>}"
[[ -f "$ISO" ]] || { echo "no such ISO: $ISO" >&2; exit 1; }
ISO="$(readlink -f "$ISO")"
command -v genisoimage >/dev/null || { echo "genisoimage missing" >&2; exit 1; }
command -v wimlib-imagex >/dev/null || { echo "wimlib-imagex missing" >&2; exit 1; }

PARENT="$(dirname "$ISO")"
WORK="$(mktemp -d -p "$PARENT" .repack.XXXXXX)"
# Distinct mountpoints for the source-copy step and the final verify step so a
# slow loop-device teardown from one can't bleed into the other.
MNT="$WORK/mnt"; VMNT="$WORK/vmnt"; TREE="$WORK/tree"; NEW="${ISO}.repack"
mkdir -p "$MNT" "$VMNT" "$TREE"
cleanup(){
    mountpoint -q "$MNT"  && umount "$MNT"  || true
    mountpoint -q "$VMNT" && umount "$VMNT" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "[1/6] Mounting and copying ISO tree..."
mount -o loop,ro "$ISO" "$MNT"
# Preserve volume id for the rebuild
VOLID="$(blkid -o value -s LABEL "$ISO" 2>/dev/null || echo WIN11)"
cp -a "$MNT"/. "$TREE"/
umount "$MNT"
chmod -R u+w "$TREE"

echo "[2/6] Joining split WIM (if any)..."
shopt -s nullglob
swm=("$TREE"/sources/install*.swm)
if (( ${#swm[@]} )); then
    # wimlib join needs install.swm first, then the rest in order.
    ordered=$(printf '%s\n' "${swm[@]}" | sort -V)
    echo "  parts: $(echo "$ordered" | tr '\n' ' ')"
    wimlib-imagex join "$TREE/sources/install.wim" $ordered
    rm -f "${swm[@]}"
    echo "  -> single install.wim: $(du -h "$TREE/sources/install.wim" | cut -f1)"
else
    echo "  already single install.wim ($(du -h "$TREE/sources/install.wim" | cut -f1)) — no join"
fi

echo "[3/6] Building UDF ISO ($VOLID)..."
[[ -f "$TREE/boot/etfsboot.com" ]] || { echo "missing BIOS boot img" >&2; exit 1; }
[[ -f "$TREE/efi/microsoft/boot/efisys.bin" ]] || { echo "missing UEFI boot img" >&2; exit 1; }
rm -f "$NEW"
genisoimage -quiet \
    -udf -allow-limited-size \
    -iso-level 3 -J -joliet-long \
    -V "$VOLID" \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
    -o "$NEW" "$TREE"
sync   # ensure the image is fully flushed before we loop-mount it to verify

echo "[4/6] Verify boot records (BIOS + UEFI)..."
# grep -c exits non-zero on 0 matches; `|| true` so set -e doesn't abort before
# the [[ ]] check reports a real message.
bios=$(xorriso -indev "$NEW" -report_el_torito plain 2>/dev/null | grep -c 'BIOS' || true)
uefi=$(xorriso -indev "$NEW" -report_el_torito plain 2>/dev/null | grep -c 'UEFI' || true)
[[ "$bios" -ge 1 && "$uefi" -ge 1 ]] || { echo "  boot record missing (BIOS=$bios UEFI=$uefi)" >&2; exit 1; }
echo "  BIOS + UEFI present"

echo "[5/6] Verify single install.wim reads at full size via UDF..."
mount -o loop,ro -t udf "$NEW" "$VMNT"
# nullglob array instead of `ls | wc -l`, which fails under pipefail on no match.
shopt -s nullglob; swmparts=("$VMNT"/sources/install*.swm); shopt -u nullglob
[[ ${#swmparts[@]} -eq 0 ]] || { echo "  still has .swm parts (${#swmparts[@]})!" >&2; exit 1; }
src_sz=$(stat -c%s "$TREE/sources/install.wim")
udf_sz=$(stat -c%s "$VMNT/sources/install.wim")
[[ "$src_sz" == "$udf_sz" ]] || { echo "  size mismatch src=$src_sz udf=$udf_sz (truncation!)" >&2; exit 1; }
wimlib-imagex info "$VMNT/sources/install.wim" 1 >/dev/null || { echo "  install.wim unreadable" >&2; exit 1; }
umount "$VMNT"
echo "  single install.wim = $udf_sz bytes, readable, no truncation"

echo "[6/6] Atomic swap into place..."
owner=$(stat -c '%U:%G' "$ISO")
mv -f "$NEW" "$ISO"
chown "$owner" "$ISO" 2>/dev/null || true
echo "Done: $ISO ($(du -h "$ISO" | cut -f1))"
