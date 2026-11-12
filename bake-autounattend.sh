#!/usr/bin/env bash
# Bake autounattend.xml into the ROOT of an existing UDF Win11 ISO (in place).
set -euo pipefail
trap 'echo "[ERROR] line $LINENO exited $?" >&2' ERR
ISO="${1:?usage: bake-autounattend.sh <iso>}"; ISO="$(readlink -f "$ISO")"
UNATTEND="${2:-/root/win-build/autounattend.xml}"
[[ -f "$ISO" && -f "$UNATTEND" ]] || { echo "missing iso or unattend" >&2; exit 1; }
WORK="$(mktemp -d -p "$(dirname "$ISO")" .bake.XXXXXX)"
MNT="$WORK/mnt"; TREE="$WORK/tree"; VMNT="$WORK/vmnt"; NEW="${ISO}.baked"
mkdir -p "$MNT" "$TREE" "$VMNT"
cleanup(){ mountpoint -q "$MNT" && umount "$MNT"||true; mountpoint -q "$VMNT" && umount "$VMNT"||true; rm -rf "$WORK"; }
trap cleanup EXIT
echo "[1/5] copy ISO tree"; mount -o loop,ro "$ISO" "$MNT"; VOLID="$(blkid -o value -s LABEL "$ISO" 2>/dev/null||echo WIN11)"; cp -a "$MNT"/. "$TREE"/; umount "$MNT"; chmod -R u+w "$TREE"
echo "[2/5] add autounattend.xml at ISO root"; cp "$UNATTEND" "$TREE/autounattend.xml"; ls -l "$TREE/autounattend.xml"
[ -f /root/win-build/setclock.cmd ] && cp /root/win-build/setclock.cmd "$TREE/setclock.cmd" && echo "  setclock.cmd added"
echo "[3/5] genisoimage UDF rebuild ($VOLID)"; rm -f "$NEW"
genisoimage -quiet -udf -allow-limited-size -iso-level 3 -J -joliet-long -V "$VOLID" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
  -o "$NEW" "$TREE"; sync
echo "[4/5] verify root autounattend + boot + single wim"
mount -o loop,ro -t udf "$NEW" "$VMNT"
[[ -f "$VMNT/autounattend.xml" ]] || { echo "autounattend missing from ISO root!" >&2; exit 1; }
shopt -s nullglob; swm=("$VMNT"/sources/install*.swm); shopt -u nullglob
[[ ${#swm[@]} -eq 0 && -f "$VMNT/sources/install.wim" ]] || { echo "install.wim not single!" >&2; exit 1; }
b=$(xorriso -indev "$NEW" -report_el_torito plain 2>/dev/null | grep -c BIOS||true); u=$(xorriso -indev "$NEW" -report_el_torito plain 2>/dev/null | grep -c UEFI||true)
echo "  autounattend@root=yes  install.wim=single  BIOS=$b UEFI=$u"
[[ "$b" -ge 1 && "$u" -ge 1 ]] || { echo "boot records incomplete" >&2; exit 1; }
umount "$VMNT"
echo "[5/5] swap into place"; own=$(stat -c '%U:%G' "$ISO"); mv -f "$NEW" "$ISO"; chown "$own" "$ISO" 2>/dev/null||true
echo "DONE: $ISO ($(du -h "$ISO"|cut -f1))"
