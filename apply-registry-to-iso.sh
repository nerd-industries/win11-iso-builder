#!/usr/bin/env bash
# Re-apply the builder's bake_oobe_registry() to an existing ISO, in place (verified, atomic).
set -euo pipefail
ISO="$1"; LOG=/tmp/apply-reg.log; DONE=/tmp/apply-reg.done; rm -f "$DONE"; exec >"$LOG" 2>&1
trap 'echo FAIL >"$DONE"' ERR
hdr(){ echo "== $*"; }; log(){ echo "  $*"; }; die(){ echo "DIE: $*"; exit 1; }
eval "$(sed -n '/^bake_oobe_registry() {/,/^copy_enabler_script() {/p' /root/win-build/win11-builder.sh | sed '$d')"
W=$(mktemp -d -p "$(dirname "$ISO")" .reg.XXXXXX); mkdir -p "$W/m" "$W/v"; STAGING="$W/tree"
mount -o loop,ro "$ISO" "$W/m"; VOL=$(blkid -o value -s LABEL "$ISO"); cp -a "$W/m"/. "$STAGING"/; umount "$W/m"; chmod -R u+w "$STAGING"
bake_oobe_registry
genisoimage -quiet -udf -allow-limited-size -iso-level 3 -J -joliet-long -V "$VOL" \
  -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
  -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot -o "$ISO.new" "$STAGING"; sync
mount -o loop,ro -t udf "$ISO.new" "$W/v"; rm -rf "$W/h"; mkdir "$W/h"
wimlib-imagex extract "$W/v/sources/install.wim" 1 /Windows/System32/config/SYSTEM /Windows/System32/config/SOFTWARE --dest-dir="$W/h" --no-acls >/dev/null
echo "VERIFY PreventDeviceEncryption=$(hivexget "$W/h/SYSTEM" 'ControlSet001\Control\BitLocker' PreventDeviceEncryption) SAC=$(hivexget "$W/h/SYSTEM" 'ControlSet001\Control\CI\Policy' VerifiedAndReputablePolicyState) Sku=$(hivexget "$W/h/SYSTEM" 'ControlSet001\Control\CI\Policy' SkuPolicyRequired) BypassNRO=$(hivexget "$W/h/SOFTWARE" 'Microsoft\Windows\CurrentVersion\OOBE' BypassNRO)"
echo "VERIFY root files: $(ls "$W/v" | grep -cE '^(autounattend.xml|setclock.cmd)$')/2"
umount "$W/v"
b=$(xorriso -indev "$ISO.new" -report_el_torito plain 2>/dev/null | grep -c BIOS || true); u=$(xorriso -indev "$ISO.new" -report_el_torito plain 2>/dev/null | grep -c UEFI || true)
echo "VERIFY boot BIOS=$b UEFI=$u"; [ "$b" -ge 1 ] && [ "$u" -ge 1 ]
mv -f "$ISO.new" "$ISO"; rm -rf "$W"; echo "DONE"; echo OK >"$DONE"
