# win11-iso-builder

Daily-rebuilt Windows 11 25H2 Pro ISO with hardware-requirement bypasses (TPM/SecureBoot/RAM) and Intel RST storage drivers preinjected. Hosted behind a single-shared-password web page exposed via Cloudflare Tunnel. Email notifications on success/failure via Resend.

Built for repair shops, lab environments, and anyone who installs Windows 11 on unsupported hardware often enough to want a current bypass-ready ISO available from anywhere with internet.

> **Hybrid architecture:** Linux orchestrates everything; a Windows VM runs `DISM` (the only step that genuinely cannot run on Linux) for cumulative-update integration. If you want a pure-Linux pipeline, the Linux UUP Dump converter cannot apply Cumulative Updates — you'd ship 24H2 RTM, not the latest 25H2 cumulative. The Windows worker exists to close that gap.

---

## What you get

A daily-fired pipeline that:

1. Polls UUP Dump's API for the latest Windows 11 25H2 build.
2. SSHes to a Windows worker VM, which fetches the UUP package and runs Microsoft's official converter with `AddUpdates=1` (DISM-applies the cumulative updates offline).
3. SCPs the resulting CU-integrated vanilla ISO back to the Linux orchestrator.
4. Applies "Rufus-style" hardware-bypass patches to `boot.wim`:
   - LabConfig registry keys (`BypassRAMCheck`, `BypassTPMCheck`, `BypassSecureBootCheck`)
   - `HwReqChkVars` REG_MULTI_SZ with fake-passing values
   - `winsetup.dll` UTF-16LE binary patch (`Module_Init_HWRequirements` → `Module_Init_GatherDiskInfo`)
   - Removes `SetupPrep.exe`/`SetupHost.exe` to force the classic installer
5. Replaces `appraiserres.dll` with the Win10 15063 version.
6. Adds a generic `ei.cfg` to bypass the product-key gate.
7. Injects Intel RST drivers into every image of `boot.wim` under `\$WinPEDriver$\` (auto-loaded by WinPE; persisted into the installed OS).
8. Splits `install.wim` into `.swm` chunks (works around ISO9660 4 GiB limit on Debian's xorriso, which lacks UDF).
9. Builds the final BIOS+UEFI bootable ISO.
10. Deploys to a directory served by FastAPI behind a Cloudflare Tunnel.
11. Emails the download URL to the configured address.

---

## What you need

| Resource | Purpose |
|---|---|
| **Linux VM** (Debian 13+) — the "orchestrator" | Runs the pipeline, hosts the web UI |
| **Windows VM** (Server 2025 Core or Win11 Pro) | Runs DISM offline servicing for CU integration |
| **Cloudflare account + a domain on it** | Public TLS + tunnel from the LAN to the internet, no port forwarding needed |
| **Resend account** ([resend.com](https://resend.com)) | Email notifications. Free tier (100/day) is plenty |
| **Win 11 Boot And Upgrade FIX KIT v6.1f2** ([MyDigitalLife forums](https://forums.mydigitallife.net/), password-protected zip) | Provides `appraiserres.dll`, `ei.cfg`, `24H2_Online_Upgrade_Enabler_Script.cmd` |
| **`RST_ALL_DRIVERS.tar.gz`** | Intel RST AHCI/RAID/VMD drivers for Intel chipset gens 8-15. Source from Intel's driver site or build your own — NOT redistributed in this repo for license reasons. Place at the repo root before installing. |

This repo intentionally does **not** include the FIX KIT or the RST drivers — they're third-party and governed by their own licenses. You source them yourself.

---

## Topology

```
┌─ Public internet ───────────────────────────────────┐
│  https://windows.example.com  (browser/curl/IDM)    │
└────────────────────┬────────────────────────────────┘
                     │ HTTPS (CF terminates TLS)
                     ▼
              Cloudflare edge
                     │ Cloudflare Tunnel (QUIC, no inbound ports)
                     ▼
┌─ Your LAN ──────────────────────────────────────────┐
│                                                     │
│  Linux orchestrator                                 │
│   ├─ cloudflared.service ── 127.0.0.1:8080          │
│   ├─ iso-server.service (FastAPI)                   │
│   │    serves /srv/iso/*.iso                        │
│   ├─ win11-check.timer (daily) → win11-check.sh     │
│   └─ win11-builder.sh (the pipeline)                │
│        │ ssh                                        │
│        ▼                                            │
│  Windows worker (DISM-only role)                    │
│   └─ C:\Tools\Build-Iso.ps1                         │
│        runs uup_download_windows.cmd, returns ISO   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

Linux is the brain. Windows does only the one thing Microsoft's design forces you to use Windows for (DISM offline servicing). Everything else — UUP polling, scheduling, hardware-bypass patches, RST injection, ISO assembly, web hosting, email — lives on Linux.

---

## Quick start

### 1. Prepare the Windows worker

A separate guide should be written for your environment, but at minimum:

- Provision a Windows VM (Server 2025 Core eval works, free for 180 days, re-armable; or any Win11 Pro you have a key for). Allocate **at least 120 GB disk** — DISM scratch space spikes during CU integration.
- Install OpenSSH Server, set PowerShell as the default SSH shell.
- Add the Linux orchestrator's SSH public key to `C:\ProgramData\ssh\administrators_authorized_keys` with strict ACLs (Administrators + SYSTEM only).
- Disable Windows Defender real-time monitoring (it slows DISM ~10x by scanning every CAB extract):
  ```powershell
  Set-MpPreference -DisableRealtimeMonitoring $true
  Set-MpPreference -DisableBehaviorMonitoring $true
  ```
- Set a static LAN IP. The default in this repo is `192.0.2.7` (RFC 5737 reserved-for-docs); override via `WIN_WORKER_HOST` env var or edit `win11-builder.sh` and `windows-worker/deploy.sh`.

### 2. Prepare the Linux orchestrator

- Debian 13+ recommended. Other distros likely work but `install_deps()` in `win11-builder.sh` uses `apt`.
- SSH from the Linux VM to the Windows worker must succeed via key auth without a password prompt.
- Disable port forwarding entirely. Set up a Cloudflare Tunnel pointed at `http://localhost:8080`. See [Cloudflare's Zero Trust dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels.

### 3. Source the third-party assets

```bash
# 1. Clone this repo
git clone https://github.com/<you>/win11-iso-builder.git /root/win-build
cd /root/win-build

# 2. Place the FIX KIT (extracted with its known password)
sudo apt install -y p7zip-full
7z x -p<KIT_PASSWORD> /path/to/Win_11_Boot_And_Upgrade_FiX_KiT_v6.1f2.zip -o/tmp/win_fix_kit/

# 3. Place the RST drivers archive at the repo root
cp /path/to/RST_ALL_DRIVERS.tar.gz /root/win-build/

# 4. (Optional) override defaults via env vars
export WIN_WORKER_HOST=192.0.2.7         # your worker's LAN IP
```

### 4. Run the installer

```bash
sudo ./install-hosting.sh
```

You'll be prompted for:
- **Shared ISO password** (any secret you want; tell your team)
- **Resend API key** (`re_xxx` from <https://resend.com/api-keys>)
- **Public URL** (`https://windows.example.com` — must match your CF Tunnel hostname)
- **Email recipient**

To skip prompts (CI/automated installs), export the variables before running:

```bash
export ISO_PASSWORD='hunter2'
export RESEND_API_KEY='re_xxx'
export PUBLIC_URL='https://windows.example.com'
export RESEND_TO='you@example.com'
sudo -E ./install-hosting.sh
```

The installer:
- Creates the `winbuild` system user
- Builds the FastAPI app's Python venv
- Writes `/etc/iso-server.env` (chmod 600, owned by `winbuild`)
- Installs three systemd units (`iso-server.service`, `win11-check.service`, `win11-check.timer`)
- Probes the Windows worker; if reachable, deploys `Build-Iso.ps1` to it

### 5. Verify

```bash
sudo systemctl is-active iso-server.service       # active
sudo systemctl list-timers win11-check.timer      # next fire within ~24h
curl -sI https://windows.example.com/login        # HTTP/2 200
```

### 6. Trigger a manual build

```bash
sudo systemctl start win11-check.service          # returns in <1s (Type=simple)
sudo tail -F /var/log/win11-builder/check.log     # watch progress
```

Build takes 1-2 hours total (UUP download + DISM CU integration on Windows = 30-90 min, then SCP + Linux patches + ISO build = 15-30 min). When done, you receive an email with the download URL.

---

## Configuration

All runtime config is in `/etc/iso-server.env` (created by the installer, chmod 600). You can also override per-session via env vars:

| Env var | Default | Purpose |
|---|---|---|
| `ISO_PASSWORD` | (prompted at install) | Shared download password |
| `ISO_COOKIE_SECRET` | random base64 (auto-generated) | HMAC key for the login cookie |
| `ISO_DIR` | `/srv/iso` | Where deployed ISOs live |
| `PUBLIC_URL` | (prompted at install) | Used in the success email body |
| `RESEND_API_KEY` | (prompted at install) | Resend API key |
| `RESEND_FROM` | `onboarding@resend.dev` | Sender. For better deliverability, verify a domain on Resend and use `you@yourdomain.com` |
| `RESEND_TO` | (prompted at install) | Email recipient |
| `WIN_WORKER_USER` | `administrator` | SSH user on the Windows worker |
| `WIN_WORKER_HOST` | `192.0.2.7` | LAN IP/hostname of the Windows worker |

---

## Daily download flow (for your team)

1. Visit your `PUBLIC_URL` in a browser.
2. Enter the shared password.
3. Click `download` next to the latest ISO.

For download managers (IDM/JDownloader/aria2/wget/curl), three auth methods work on the same URL — pick whichever fits the tool:

```bash
# HTTP Basic auth (any username, password = ISO_PASSWORD)
curl -u 'any:hunter2' -O https://windows.example.com/iso/Win11-25H2-Pro-XXXXX.YYYY-RST-Rufus.iso

# Or query token
curl -O 'https://windows.example.com/iso/Win11-25H2-Pro-XXXXX.YYYY-RST-Rufus.iso?token=hunter2'

# Or browser cookie (visit /login first to get one)
```

All three doors are constant-time-compared against the same `ISO_PASSWORD`.

---

## Repo layout

```
.
├── README.md                       This file
├── LICENSE                         MIT
├── .gitignore
│
├── win11-builder.sh                Main pipeline (~600 lines bash)
├── win11-builder.md                User-facing doc
├── win11-check.sh                  Daily wrapper (deployed to /usr/local/bin/)
├── install-hosting.sh              One-shot installer
│
├── iso-server/                     FastAPI web app
│   ├── app.py                      ~250 lines, single file
│   ├── requirements.txt            Pinned deps
│   ├── pytest.ini
│   ├── tests/                      25 pytest tests covering auth + listing + Range edge cases
│   ├── templates/                  Jinja2 (base, login, list)
│   └── static/style.css            Dark monospace theme
│
├── windows-worker/
│   ├── Build-Iso.ps1               PowerShell script that runs on the worker
│   └── deploy.sh                   SCPs Build-Iso.ps1 to the worker
│
└── systemd/
    ├── iso-server.service          Web app unit
    ├── win11-check.service         Daily build oneshot (Type=simple)
    └── win11-check.timer           Daily timer (OnCalendar=daily, RandomizedDelaySec=2h)
```

Runtime locations created by the installer (NOT in repo):

```
/srv/iso/                            ISO storage (last 3, owned winbuild:winbuild)
/srv/iso-server/                     Deployed FastAPI app
/srv/iso-server/.venv/               Python virtualenv
/etc/iso-server.env                  Secrets (chmod 600, winbuild:winbuild)
/var/log/win11-builder/check.log     Daily run log
/usr/local/bin/win11-check.sh        Wrapper (copy of repo file)
/etc/systemd/system/{iso-server,win11-check}.{service,timer}
```

---

## Auth model

The FastAPI app's auth predicate accepts **any** of three doors, all using the same shared `ISO_PASSWORD`:

1. **Signed cookie** — set after `POST /login` succeeds. `urlsafe_b64(expiry).urlsafe_b64(hmac_sha256(secret, expiry))`. 7-day expiry. `Secure`, `HttpOnly`, `SameSite=Lax`. Browser-friendly.
2. **HTTP Basic auth** — username field is ignored, password must match. Download-manager friendly.
3. **`?token=` query string** — works with anything that fetches a URL. Right-click → copy link → paste into IDM/wget/curl.

All comparisons use `hmac.compare_digest` (constant-time) to defeat timing attacks.

Path-traversal guard on `/iso/{name}` uses `Path.resolve()` + `Path.is_relative_to(iso_root)` — robust against `../`, URL-encoded variants, and symlinks pointing outside `ISO_DIR`.

HTTP Range requests are supported natively via Starlette's `FileResponse` (FastAPI 0.118+ / Starlette ≥0.45). Suffix ranges (`bytes=-N`), open-ended (`bytes=N-`), past-EOF clamping, and 416 unsatisfiable are all handled.

---

## How verification works

The pipeline cannot rely on `dism /Get-WimInfo` `Version` metadata to confirm CU integration. Microsoft's design has install.wim's `Version` field stay at the **base family** (`10.0.26100`) even after the 25H2 enablement applies — the enablement flips at runtime/install-time, not in the offline WIM. Microsoft's own 25H2 install media has the same property.

UUP Dump's converter, however, **names the produced ISO from the actual integrated build** (e.g. `26200.8328.260427-1721.25H2_GE_RELEASE_...`). The pipeline verifies via filename match:

- **Windows side** (`Build-Iso.ps1`): after the converter completes, mounts the produced ISO, checks the filename contains the requested `$Build`. Fails with a clear error if not.
- **Linux side** (`verify_build_number()`): after SCP, checks the basename of `$BASE_ISO` contains `$BUILD`, plus a sanity check that install.wim is well-formed (Major/Minor/Build/SPBuild parseable, build family in the {26100, 26200} set).

If you adapt this for a future Windows version, update both filename-match checks.

---

## Known gotchas

These bit during development. Documented so they don't bite you.

1. **UUP Dump's Linux converter cannot apply Cumulative Updates.** That's why the Windows worker exists. Don't try to remove it — you'll ship a 24H2 RTM ISO instead of the 25H2 latest cumulative.
2. **`dism /Get-WimInfo` Version metadata stays at base.** See "How verification works" above.
3. **`autodl=3` doesn't work.** UUP Dump's `get.php` requires POST with form fields `autodl=2 updates=1 cleanup=1`. Bare GET or autodl=3 returns HTTP 400.
4. **Windows OpenSSH defaults to PowerShell shell**, which double-quotes args passed via SSH. Don't put single-quoted values in your SSH command — they'll arrive at the script with literal embedded quotes. UUID, edition, lang, and build all have no spaces, so unquoted is safe.
5. **SSH disconnect kills remote process tree.** A 1-3 hour build that loses its SSH session loses everything. Bash's `$()` capture in `fetch_iso_from_windows()` keeps SSH open for the full duration. If you launch from a place with a short-lived SSH client, wrap with `nohup` or schedule via Windows Task Scheduler.
6. **Windows Defender scans `%TEMP%`.** DISM scratches there. Real-time scanning slows DISM ~10x. The provisioning step disables RT monitoring.
7. **DISM offline servicing needs ~50-60 GB scratch space** during CU application. Plan disk accordingly.
8. **NetBIOS hostname max is 15 chars.** Anything longer silently truncates.
9. **Debian's xorriso lacks UDF.** This repo splits `install.wim` into `.swm` chunks at 3500 MiB each as the workaround.
10. **xorriso 1.5.6 dropped `-boot-load-seg`, `-allow-limited-size`, and `-udf`.** The build_iso command is written for 1.5.6+. If you target older xorriso, restore those flags.
11. **systemd `Type=oneshot` blocks `systemctl start` until the script exits.** Use `Type=simple` for long-running services so manual triggers return immediately.
12. **Bash `BASE_ISO=""` global init clobbers env-var override.** This repo uses `BASE_ISO="${BASE_ISO:-}"` to preserve env values.
13. **PowerShell unicode em-dashes in script source can cause parse errors** when SCPed via different encodings. Use ASCII-only.
14. **Windows OpenSSH's "Service Type → URL" in CF Tunnel config is the LOCAL connection.** Use `HTTP` for `localhost:8080`; CF terminates public TLS automatically. Setting it to `HTTPS` produces 502s.

---

## License

MIT. See `LICENSE`.

This repo's code is MIT-licensed. The third-party assets it depends on (Win 11 FIX KIT, Intel RST drivers, Microsoft Windows itself) are governed by their own licenses — you source them yourself, this repo doesn't redistribute them.

---

## Acknowledgements

- The MyDigitalLife forums community for the Win 11 Boot And Upgrade FIX KIT v6.1f2 (the source of the Rufus-style hardware bypass values).
- [UUP Dump](https://uupdump.net/) for hosting the UUP file catalog and the Windows-side converter.
- [Cloudflare Zero Trust](https://www.cloudflare.com/products/zero-trust/) for the free tunnel that closes the "expose a service without opening ports" loop.
- [Resend](https://resend.com) for clean transactional email API.
- The pipeline architecture (Linux orchestrator + Windows worker) follows the principle that you should run code on whatever OS makes that code easiest to write — even if that means crossing a host boundary.
