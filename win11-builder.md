# Windows 11 25H2 Pro ISO Builder

Automated pipeline that fetches the latest Windows 11 25H2 (build 26200.x) **as a
CU-integrated vanilla ISO** from a Windows worker VM (which uses DISM offline
servicing — the only Windows-only piece), then applies hardware-requirement
bypasses, forces the classic fast installer, injects Intel RST drivers, and
produces the final bootable ISO. Linux orchestrates everything; the Windows
worker is a stateless factory invoked over SSH for one task: DISM-based
cumulative update integration that the Linux UUP converter cannot do.

> **Worker provisioning:** see `docs/superpowers/setup-windows-builder-vm.md` for
> the one-time Windows worker VM setup. Once provisioned (192.0.2.7 by default),
> the daily build pipeline never touches it again — it just SSHes in.

> **Build numbering note:** Microsoft ships 24H2 as `26100.x` and 25H2 as
> `26200.x` (separate base, not an enablement-package flip). Earlier versions
> of this doc had the family numbers backwards.

---

## What it does

| Step | Action |
|------|--------|
| 1 | Queries UUP Dump API for the latest **26200.x** amd64 build whose title is `Windows 11, version 25H2 (XXXXX.YYYY)` (skips Preview/Cumulative/OOBE update packages) |
| 2 | SSH's to the Windows worker (`your-windows-worker` at `192.0.2.7`) and runs `Build-Iso.ps1`, which fetches the UUP package with `autodl=3`, runs UUP Dump's official Windows converter (downloads + DISM-applies CUs + builds ISO), then prints the ISO path |
| 3 | SCPs the resulting **CU-integrated vanilla ISO** back to the Linux working dir |
| 4 | Extracts the ISO to a staging directory |
| 5 | **Verifies** install.wim's `Build.SPBuild` matches the API claim (now reliably passes — the Windows side already did CU integration) |
| 6 | **Option 2a** — modifies `boot.wim` index 2 (LabConfig + HwReqChkVars + winsetup.dll patch) |
| 7 | **Option 6** — replaces `sources/appraiserres.dll` with Win10 15063 version |
| 8 | **Option 8** — adds a generic `ei.cfg` to `sources/` (bypasses product key gate) |
| 9 | **Injects Intel RST drivers** into every image of `boot.wim` under `\$WinPEDriver$\` (auto-loaded by WinPE; Setup persists them into the installed OS) and to ISO root `\Drivers\` as a manual-install fallback |
| 10 | Copies `24H2_Online_Upgrade_Enabler_Script.cmd` to the ISO root and removes `SetupPrep.exe` / `SetupHost.exe` from `boot.wim` (forces classic installer) |
| 11 | Builds the final bootable ISO with `xorriso` (BIOS + UEFI) named `Win11-25H2-Pro-${BUILD}-RST-Rufus.iso` |

### Option 2a — boot.wim modifications in detail

These changes live inside **boot.wim index 2** (the Windows PE setup environment).
They are applied by extracting the relevant files, patching them, and re-injecting.

**SYSTEM hive** (`\Windows\System32\config\SYSTEM`)
- Creates `Setup\LabConfig` at the hive root
- Sets `BypassRAMCheck`, `BypassTPMCheck`, `BypassSecureBootCheck` = DWORD `1`

**SOFTWARE hive** (`\Windows\System32\config\SOFTWARE`)
- Deletes `AppCompatFlags\CompatMarkers`, `\Shared`, `\TargetVersionUpgradeExperienceIndicators`
- Adds `AppCompatFlags\HwReqChk\HwReqChkVars` (REG_MULTI_SZ) with fake passing values:
  ```
  SQ_SSE2ProcessorSupport=TRUE, SQ_SSE4_2ProcessorSupport=TRUE,
  SQ_NXProcessorSupport=TRUE, SQ_CompareExchange128=TRUE,
  SQ_LahfSahfSupport=TRUE, SQ_PrefetchWSupport=TRUE,
  SQ_PopCntInstructionSupport=TRUE, SQ_SecureBootCapable=TRUE,
  SQ_SecureBootEnabled=TRUE, SQ_TpmVersion=2, SQ_RamMB=9999,
  SQ_SystemDiskSizeMB=99999, SQ_CpuCoreCount=9, SQ_CpuModel=99,
  SQ_CpuFamily=99, SQ_CpuMhz=9999
  ```

**winsetup.dll** — UTF-16LE binary patch
- Replaces `Module_Init_HWRequirements` → `Module_Init_GatherDiskInfo` (52 bytes, same length)
- Both occurrences are patched; suppresses the hardware requirements check in legacy setup

**SetupPrep.exe / SetupHost.exe removal**
- Deleted from `/sources/` and all WinSxS component store copies
  (`setup360-media-base` → SetupPrep, `setup360-media-onecore` → SetupHost)
- Without these files, Windows setup falls back to the classic "Copying Files" installer
  (single restart, much faster than the modern multi-restart setup)

Values sourced directly from `Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2` Option 2a.

---

## Files required

The script expects the **Win 11 Boot And Upgrade FiX KiT v6.1f2** extracted at:

```
/tmp/win_fix_kit/Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2/
└── Files/
    ├── appraiserres.dll                    (Win10 15063 version)
    ├── ei.cfg                              (generic, no channel restriction)
    └── 24H2_Online_Upgrade_Enabler_Script.cmd
```

The zip is password-protected: **`MDL2025`**

Extract with:
```bash
7z x -pMDL2025 Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2.zip -o/tmp/win_fix_kit/
```

---

## Dependencies

### Arch Linux (original system)
```bash
sudo pacman -S aria2 cabextract p7zip chntpw wimlib-tools xorriso jq python-hivex
```
The script auto-installs any of these that are missing via `pacman`.

### Debian 13 (migration target)
Package names differ — **update `install_deps()` in the script**:

```bash
sudo apt install -y \
    aria2 \
    cabextract \
    p7zip-full \
    chntpw \
    wimtools \
    xorriso \
    jq \
    python3-hivex \
    rsync
```

> **`wimtools`** provides `wimlib-imagex` on Debian (same binary, different package name).
> **`python3-hivex`** provides the Python `hivex` module on Debian.

Also replace the `install_deps()` function body in the script — swap `pacman -S --noconfirm` for `apt install -y`.

---

## Configuration

Edit these variables at the top of `win11-builder.sh` if needed:

| Variable | Default | Purpose |
|----------|---------|---------|
| `KIT_DIR` | `/tmp/win_fix_kit/Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2` | Path to extracted kit |
| `WORK_DIR` | `/tmp/win11-builder` | Working directory (needs ~30 GB free) |
| `TARGET_PREFIX` | `26200` | Build family filter — `26200` = 25H2, `26100` = 24H2 |
| `TARGET_VERSION_NAME` | `25H2` | Title-pattern filter — must match the version name UUP Dump uses in the title, e.g. `Windows 11, version 25H2 (...)` |
| `WIN_WORKER_USER` | `administrator` | Username on the Windows worker (env var override) |
| `WIN_WORKER_HOST` | `192.0.2.7` | Hostname/IP of the Windows worker (env var override) |
| `WIN_WORKER_SCRIPT` | `C:\Tools\Build-Iso.ps1` | Worker-side script path (rarely needs changing) |

---

## Usage

### Full run (download + build)
```bash
chmod +x win11-builder.sh
./win11-builder.sh
```

### Skip download — start from an existing base ISO
```bash
BASE_ISO=/path/to/base.iso ./win11-builder.sh
```

### Skip download + extract — start from an already-extracted staging dir
```bash
STAGING=/tmp/win11-builder/staging ./win11-builder.sh
```
Useful for re-running the modification/build steps without waiting for the UUP download again.

---

## Output

```
/tmp/win11-builder/Win11-25H2-Pro-26200.XXXX-RST-Rufus.iso
```

Volume label format: `WIN_11_26200_XXXX_X64_EN-US`

The companion `install-hosting.sh` sets up a daily systemd timer that:
- Polls UUP Dump for newer 25H2 builds
- Runs this builder if a newer build exists
- Moves the result to `/srv/iso/`, prunes to the last 3
- Serves them at `https://windows.example.com` (via Cloudflare Tunnel)
- Emails `you@example.com` on success or failure (via Resend)

---

## Bundled drivers

`RST_ALL_DRIVERS.tar.gz` (in this directory) ships 6 Intel RST driver packages
covering AHCI / RAID / VMD modes for chipset gens 8-9, 10-11, and 12-15.

The injection runs automatically as step 9. Drivers are placed in two locations:

1. **`boot.wim` → `\$WinPEDriver$\`** — WinPE auto-scans this path at boot,
   loads matching INFs by hardware ID, and Setup persists the loaded drivers
   into the installed OS's driver store. This is the primary mechanism.

2. **ISO root → `\Drivers\`** — a plain copy as manual-install fallback. From
   the installed OS, `pnputil /add-driver C:\path\to\inf /install` works.

Driver binding is hardware-ID-matched, so unmatched INFs are inert on systems
that don't have the corresponding controller. No risk to AMD or other-vendor
hardware.

---

## Notes

- **ISO size**: ~5–6 GB (Pro edition only, no Home, no updates baked in)
- **UUP download time**: 30–90 min depending on connection
- **Total build time**: ~1–2 hours
- **Disk space needed**: ~30 GB free in `WORK_DIR` during build
- The script is idempotent for the modification steps — running with `STAGING=` set
  re-applies all patches to the same staging directory
- The boot ISO uses BIOS (etfsboot.com, segment 0x07C0) + UEFI (efisys.bin) El Torito entries
- The ISO works directly with Rufus or any standard USB-burning tool
