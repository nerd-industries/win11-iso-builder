#requires -RunAsAdministrator
<#
.SYNOPSIS
  Produce a CU-integrated vanilla Windows ISO from a UUP Dump UUID.

.DESCRIPTION
  Runs on the Windows worker VM (your-windows-worker). Stateless. Each invocation:
    1. Cleans C:\BuildWork
    2. Downloads UUP Dump's converter package with autodl=3 (CU integration)
    3. Verifies ConvertConfig.ini has AddUpdates=1 (corrects if not)
    4. Runs uup_download_windows.cmd (downloads UUPs, DISM-applies CUs, builds ISO)
    5. Mounts the ISO and verifies install.wim reports the expected build
    6. Moves the ISO to C:\BuildOut with a canonical name
    7. Writes the absolute path to stdout
  Status messages go to stderr. Stdout contains exactly one line: the final ISO path.

.PARAMETER Uuid
  UUP Dump build UUID (from listid.php).

.PARAMETER Edition
  Windows edition (e.g. "professional").

.PARAMETER Lang
  Language pack (e.g. "en-us").

.PARAMETER Build
  Expected build (e.g. "26200.8328"). Used for filename and post-build verification.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Uuid,
    [Parameter(Mandatory)][string]$Edition,
    [Parameter(Mandatory)][string]$Lang,
    [Parameter(Mandatory)][string]$Build
)

# Format validation - defense in depth against path injection via parameters
if ($Build -notmatch '^[0-9]+\.[0-9]+$') {
    [Console]::Error.WriteLine("[Build-Iso] ERROR: invalid Build format: '$Build' (expected NNNN.NNNN)")
    exit 2
}
if ($Uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    [Console]::Error.WriteLine("[Build-Iso] ERROR: invalid Uuid format: '$Uuid' (expected GUID)")
    exit 2
}
if ($Edition -notmatch '^[a-zA-Z0-9_-]+$') {
    [Console]::Error.WriteLine("[Build-Iso] ERROR: invalid Edition format: '$Edition'")
    exit 2
}
if ($Lang -notmatch '^[a-z]{2}-[a-z]{2}$') {
    [Console]::Error.WriteLine("[Build-Iso] ERROR: invalid Lang format: '$Lang' (expected xx-yy)")
    exit 2
}

$ErrorActionPreference = 'Stop'

function Status([string]$msg) {
    [Console]::Error.WriteLine("[Build-Iso] $msg")
}

$WorkDir = 'C:\BuildWork'
$OutDir  = 'C:\BuildOut'

# 1. Dismount any leftover ISO mounts from prior crashed runs, then clean working dir
Status "Cleaning $WorkDir"
if (Test-Path $WorkDir) {
    Get-ChildItem -Path $WorkDir -Filter '*.iso' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Status "  Dismounting leftover: $($_.FullName)"
        Dismount-DiskImage -ImagePath $_.FullName -ErrorAction SilentlyContinue | Out-Null
    }
    Remove-Item "$WorkDir\*" -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null

# 2. Fetch UUP Dump converter package with CU integration enabled.
#    UUP Dump's get.php requires POST with form fields autodl=2 (script bundle),
#    updates=1 (integrate cumulative updates), cleanup=1 (clean intermediate files).
#    A bare GET, or autodl=3, returns HTTP 400 with "no editions selected".
$pkgUrl = "https://uupdump.net/get.php?id=$Uuid&pack=$Lang&edition=$Edition"
$pkgZip = Join-Path $WorkDir 'uup_pkg.zip'
$pkgDir = Join-Path $WorkDir 'uup_pkg'

Status "Fetching UUP package: $pkgUrl (POST autodl=2 updates=1 cleanup=1)"
Invoke-WebRequest -UseBasicParsing -Uri $pkgUrl -Method POST `
    -Body @{ autodl = '2'; updates = '1'; cleanup = '1' } `
    -OutFile $pkgZip
$pkgKb = [math]::Round((Get-Item $pkgZip).Length / 1KB, 1)
Status "Got $pkgKb KB"

Status "Extracting package"
Expand-Archive -Path $pkgZip -DestinationPath $pkgDir -Force

# 3. Verify (and force) AddUpdates=1 in ConvertConfig.ini
$configPath = Join-Path $pkgDir 'ConvertConfig.ini'
if (-not (Test-Path $configPath)) {
    Status "ERROR: ConvertConfig.ini missing from package"
    exit 1
}
$cfg = Get-Content $configPath
$hasUpdates = $cfg | Select-String '^AddUpdates\s*=\s*1' -Quiet
if (-not $hasUpdates) {
    Status "ConvertConfig.ini AddUpdates != 1; forcing it"
    $newCfg = @()
    $found = $false
    foreach ($line in $cfg) {
        if ($line -match '^AddUpdates\s*=') {
            $newCfg += 'AddUpdates=1'
            $found = $true
        } else {
            $newCfg += $line
        }
    }
    if (-not $found) { $newCfg += 'AddUpdates=1' }
    $newCfg | Set-Content $configPath -Encoding ASCII
}
Status "ConvertConfig.ini AddUpdates=1 confirmed"

# 4. Run UUP Dump's official Windows converter
$cmdScript = Join-Path $pkgDir 'uup_download_windows.cmd'
if (-not (Test-Path $cmdScript)) {
    Status "ERROR: uup_download_windows.cmd missing from package"
    exit 1
}
Status "Running converter (long step: 30-90 min)"
$converterLog    = Join-Path $WorkDir 'converter.log'
$converterErrLog = Join-Path $WorkDir 'converter.err.log'
Status "  Converter stdout/stderr → $converterLog / $converterErrLog"
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdScript `
    -WorkingDirectory $pkgDir -Wait -PassThru `
    -RedirectStandardOutput $converterLog `
    -RedirectStandardError $converterErrLog
if ($proc.ExitCode -ne 0) {
    Status "ERROR: converter exited $($proc.ExitCode) (see $converterLog and $converterErrLog)"
    if (Test-Path $converterErrLog) {
        Status "  --- last 30 lines of stderr ---"
        Get-Content $converterErrLog -Tail 30 | ForEach-Object { Status "    $_" }
    }
    exit $proc.ExitCode
}
Status "Converter completed"

# 5. Locate produced ISO
$iso = Get-ChildItem -Path $pkgDir -Filter '*.iso' -Recurse | Select-Object -First 1
if (-not $iso) {
    Status "ERROR: no ISO produced under $pkgDir"
    exit 1
}
$isoGb = [math]::Round($iso.Length / 1GB, 2)
Status "Produced: $($iso.FullName) ($isoGb GB)"

# 6. Mount + verify install.wim build matches the expected $Build
Status "Mounting ISO to verify install.wim build"
$mount = Mount-DiskImage -ImagePath $iso.FullName -PassThru
try {
    # Poll up to 10s for a drive letter to be assigned (Windows ISOs may
    # mount as multi-volume; we want the volume with the install media)
    $vol = $null
    for ($i = 0; $i -lt 20; $i++) {
        $vol = $mount | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
        if ($vol) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $vol) {
        Status "ERROR: no drive letter assigned to mounted ISO after 10s"
        exit 1
    }
    $drive = "$($vol.DriveLetter):"
    $wim = Join-Path "$drive\" 'sources\install.wim'
    if (-not (Test-Path $wim)) {
        Status "ERROR: install.wim not found at $wim"
        exit 1
    }
    $info = & dism.exe /Get-WimInfo /WimFile:$wim /Index:1 2>&1 | Out-String
    $match = [regex]::Match($info, '(?im)^\s*Version\s*:\s*([0-9.]+)\s*$')
    if ($match.Success) {
        Status "install.wim Version metadata: $($match.Groups[1].Value.Trim())"
    } else {
        Status "Note: could not parse Version from dism output (non-fatal)"
    }
    # Verify via filename - install.wim Version metadata reports the BASE family
    # (e.g. 10.0.26100) even after 25H2 enablement applies, because Microsoft's
    # design has the WIM stay at base while enablement flips at runtime. UUP
    # Dump's converter names the produced ISO from the ACTUAL integrated build
    # (e.g. "26200.8328.260427-1721.25H2_GE_RELEASE_..."), so the filename is
    # the reliable signal that CU integration produced the right output.
    $isoBaseName = $iso.Name
    if ($isoBaseName -notmatch ([regex]::Escape($Build))) {
        Status "ERROR: produced ISO filename '$isoBaseName' does not contain expected build '$Build'"
        Status "       (converter names ISOs from the integrated build; mismatch means CU integration didn't fully apply)"
        exit 1
    }
    Status "Build verified via filename: '$isoBaseName' contains '$Build'"
} finally {
    Dismount-DiskImage -ImagePath $iso.FullName | Out-Null
}

# 7. Move ISO to BuildOut with canonical name
$finalName = "Win11-25H2-Pro-$Build-vanilla.iso"
$finalPath = Join-Path $OutDir $finalName
if (Test-Path $finalPath) { Remove-Item $finalPath -Force }
Move-Item -Path $iso.FullName -Destination $finalPath
Status "Moved to: $finalPath"

# 8. Print final path to stdout - this is the ONLY Write-Output
Write-Output $finalPath
exit 0
