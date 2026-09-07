<#
.SYNOPSIS
    bootstrap_win.ps1 - SCANBOX PC-side provisioning. Takes a bare CM4 with a blank
    eMMC to a running, deployed node with one command and one passphrase.

.DESCRIPTION
    This is the other half of scripts/deploy/bootstrap_node.sh. bootstrap_node.sh runs ON
    the node and does the deploy; bootstrap_win.ps1 runs on the operator's Windows PC
    and produces a node that will run bootstrap_node.sh by itself.

    What it replaces, step for step, is the procedure performed today: open
    Raspberry Pi Imager, fill in the OS-customisation dialog, move the nRPIBOOT
    jumper, write the image, wait, move the jumper back, find the node's
    address, SSH in, and run bootstrap_node.sh. After this script the operator moves
    the jumper twice - the two things no software can do - and types the deploy
    passphrase once.

    ONE ENCRYPTED ARTEFACT, AND NEITHER SCRIPT CARRIES IT
      The blob is not in this file and not in bootstrap_node.sh. It is published
      as token.age, served beside them, and both halves fetch it.

      It used to be pasted into both, because bash and PowerShell share no code,
      and publish_bootstrap.sh kept the two copies in step by patching them
      together and comparing them. That guard is the argument against itself: it
      covered the blob and the hint because somebody added those to it, while
      the default deploy branch is duplicated between the very same two files
      and nothing checks it. One artefact cannot drift from itself.

      This script fetches the blob for two things: to decrypt the clone token
      for a sparse checkout when this PC has no copy of the repository, and to
      decrypt the token that goes on the card.

      AND IT VERIFIES THE PASSPHRASE, which the previous design could not.
      age reads a passphrase from a terminal and from nowhere else - measured,
      not assumed - and that is true of a child process created with NO CONSOLE.
      This script runs in one, so age can prompt against it, and a successful
      decrypt IS the check. A mistyped passphrase now fails here, in a second,
      instead of surfacing on a node twenty minutes later.

      It is also asked for ONCE. The old shape prompted twice on a PC with no
      checkout - once at age's prompt for the clone, once at this script's own
      prompt for the copy that went on the card - and never compared them.

    WHAT IT NEVER STORES
      No plaintext password, ever, anywhere. The account password is handled
      only as a crypt hash - reused from Raspberry Pi Imager's own registry key
      (which never holds a plaintext either) or produced locally with
      `openssl passwd`. The deploy passphrase is never held by this script at
      all: age prompts for it against the console and this process never sees
      it. What travels to the card is the CLONE TOKEN age produced - one
      read-only, single-repo, revocable credential rather than the master key
      to every published blob - as /boot/firmware/scanbox-deploy.token, moved
      to tmpfs and shredded by the node in the first seconds of first boot,
      before the network is even up (host/cloudinit/provision.sh.tmpl says
      exactly how, and why the erase happens before the use).

.NOTES
    Windows PowerShell 5.1 ONLY. No pwsh, no 7-Zip, and no `tar -xJ` (the
    Windows bsdtar cannot read .xz). Everything here runs on a stock Windows 10
    box with Git for Windows, and it says what is missing rather than failing
    halfway.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    # Board serial - the host/profiles/<serial>.env to render from. Normally
    # read from the board itself over USB while it is in mass-storage mode;
    # give it here to override, or to render a seed with no board attached.
    [string] $Serial,

    # Run one menu action directly and exit. Same names the menu shows.
    [ValidateSet('flash', 'render', 'probe', 'cleanup', 'menu')]
    [string] $Action = 'menu',

    # Where to put a rendered seed instead of writing it to a card.
    [string] $OutDir,

    # Path to the .img.xz to write. Default: the pinned image, downloaded and
    # cached under C:\ProgramData\Scanbox\flash\images.
    [string] $Image,

    # Do not put the deploy passphrase on the card. The node still comes up
    # fully provisioned, keyed and NOPASSWD-sudo, but stops before the deploy
    # and prints the one command to run over SSH.
    [switch] $NoPassphrase,

    # Use this checkout instead of cloning. Set automatically when bootstrap_win.ps1 is
    # run from inside a scanbox checkout.
    [string] $RepoRoot,

    # Print what would happen; touch no disk, install nothing.
    [switch] $DryRun,

    # Set by Assert-Elevated on the copy it starts under UAC. It means "this
    # window was opened by the script itself", and it buys two things the first
    # window does not need: the transcript names itself a relaunch, and the
    # window WAITS for a keypress before closing. Without that wait an elevated
    # failure is unreadable - the window carries the only copy of the error and
    # closes with it. Not for hand use.
    [switch] $Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The arguments this script was actually given, captured AT SCRIPT SCOPE.
# $PSBoundParameters inside a function is that FUNCTION's bound parameters, not
# the script's: read from inside parameterless Assert-Elevated it is empty, so
# the relaunch forwarded nothing at all - not -Serial, not -Image, not
# -NoPassphrase. Captured here, it is the script's own.
$INVOKED_PARAMS = $PSBoundParameters

# =============================================================================
# Constants
# =============================================================================

# ---- the shared artefacts, fetched rather than embedded ---------------------
# This file used to carry a copy of bootstrap_node.sh's encrypted token and its hint,
# kept in step by a publisher that patched both by regular expression and then
# compared them. One artefact, two carriers, and a guard that only covered what
# somebody remembered to add to it - the default branch is duplicated the same
# way and nothing checks it.
#
# One copy now, served next to bootstrap_node.sh, fetched by both halves. Rotation
# replaces one file. The cost is that a flash needs the network to decrypt; it
# already needs it for the image, so nothing changes in practice.
# Overridable, and it has to be: the commit that introduced this said the base
# was 'derived from an overridable variable' while it was a literal here. A fork
# or a mirror must be able to serve its own artefacts to its own halves.
$DEPLOY_BASE_URL = if ($env:SCANBOX_DEPLOY_BASE_URL) { $env:SCANBOX_DEPLOY_BASE_URL }
                   else { 'https://raw.githubusercontent.com/Alkaronyan/scanbox-deploy/main' }
$TOKEN_AGE_URL   = "$DEPLOY_BASE_URL/token.age"
$HINT_URL        = "$DEPLOY_BASE_URL/token.age.hint"

$REPO_BRANCH   = 'uvc-webcam-beta'
$REPO_URL      = 'https://github.com/Alkaronyan/scanbox.git'
$BOOTSTRAP_URL = "$DEPLOY_BASE_URL/bootstrap_node.sh"
# Where this file itself is served. Only used to tell an operator who piped it
# into Invoke-Expression how to run it properly - see Assert-Elevated.
$BOOTSTRAP_WIN_URL = "$DEPLOY_BASE_URL/bootstrap_win.ps1"

# The pinned OS image: Debian 13 (trixie) 64-bit Lite, Raspberry Pi build.
# IMAGE_RAW_SHA256 is the hash of the DECOMPRESSED .img - it is the value
# Raspberry Pi publish as extract_sha256 and the one rpi-imager verifies
# against. Both hashes were confirmed by downloading and decompressing this
# exact file on 2026-09-05.
$IMAGE_URL        = 'https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-06-19/2026-06-18-raspios-trixie-arm64-lite.img.xz'
$IMAGE_NAME       = '2026-06-18-raspios-trixie-arm64-lite.img.xz'
$IMAGE_XZ_SHA256  = 'acff736ca7945e3b305f07cda4abdb870910e12634991da69783611756e381b3'
$IMAGE_RAW_SHA256 = 'e235fd24fc5f039c08daba7d3abc04aecc7313f979d16d2a3fdad29dd44c33a9'

# The kernel that image ships for a CM4 (its /usr/lib/modules, read from the
# mounted image on 2026-09-05). Reconciled against host/kernel/SUPPORTED_KERNELS
# by Test-KernelAllowlist, so that bumping $IMAGE_URL without validating the
# kernel is caught here rather than by a deploy that refuses to build modules.
$IMAGE_KERNEL_V8  = '6.18.34+rpt-rpi-v8'

$STATE_DIR     = Join-Path $env:ProgramData 'Scanbox\flash'
$MANIFEST_PATH = Join-Path $STATE_DIR 'manifest.json'
$HASH_PATH     = Join-Path $STATE_DIR 'pwhash.txt'
$KEYS_PATH     = Join-Path $STATE_DIR 'authorized_keys.txt'
$IMAGE_DIR     = Join-Path $STATE_DIR 'images'
$CLONE_DIR     = Join-Path $STATE_DIR 'repo'

$RPIBOOT_DIR    = 'C:\Program Files (x86)\Raspberry Pi'
$RPIBOOT_EXE    = Join-Path $RPIBOOT_DIR 'rpiboot.exe'
$RPIBOOT_GADGET = Join-Path $RPIBOOT_DIR 'mass-storage-gadget64'
$RPIBOOT_URL    = 'https://github.com/raspberrypi/usbboot/releases/latest/download/rpiboot_setup.exe'

# ---- the three the script used to refuse on ---------------------------------
# It installed rpiboot and then threw at `age`, Git and Imager with a winget
# line for the operator to run. That makes "one command from a bare PC" false:
# the two it needs FIRST - age to decrypt the clone token, git to fetch the
# three directories it reads - are exactly the two a machine with no checkout
# does not have. Same pattern as rpiboot now, with the same manifest discipline:
# whatever pre-existed is recorded as such and cleanup never touches it.
#
# VERSION AND HASH ARE PINNED, like the OS image, not `latest`. A moving URL
# would install something nobody checked, and the day it moved the run would
# differ from every run before it with nothing saying so. Updating a pin is a
# commit; that is the point. Hashes measured 2026-09-07 by downloading each once.
$DEP_DIR = Join-Path $STATE_DIR 'bin'

$AGE_VERSION = 'v1.3.2'
$AGE_URL     = "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-windows-amd64.zip"
$AGE_SHA256  = 'f48d8f8f9ebe903ab5027ed067652f2cc1db94bc206976430133b905dcd8e8c7'
$AGE_EXE     = Join-Path $DEP_DIR 'age.exe'

$GIT_VERSION = '2.55.0.5'
$GIT_URL     = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/Git-2.55.0.5-64-bit.exe'
$GIT_SHA256  = 'd065a4e23c3d9a6b5073d609b5be0830227ec3ca053c083ba385061ddfaf94c6'

$IMAGER_VERSION = '2.0.11.1'
$IMAGER_URL     = "https://downloads.raspberrypi.org/imager/imager_$IMAGER_VERSION.exe"
$IMAGER_SHA256  = '94ffded522f3e2a38bdb9505440229e1411b80992a616ba16b2d7e73bd794130'

$IMAGER_DIR = 'C:\Program Files\Raspberry Pi Ltd\Imager'
$IMAGER_EXE = Join-Path $IMAGER_DIR 'rpi-imager.exe'

$IMAGER_REG = 'HKCU:\SOFTWARE\Raspberry Pi\Raspberry Pi Imager\imagecustomization'

# =============================================================================
# Output
# =============================================================================

function Write-Step  { param([string] $m) Write-Host "[flash] $m" -ForegroundColor Cyan }
function Write-Ok    { param([string] $m) Write-Host "  ok   $m" -ForegroundColor Green }
function Write-Warn2 { param([string] $m) Write-Host "  warn $m" -ForegroundColor Yellow }
function Write-Bad   { param([string] $m) Write-Host "  FAIL $m" -ForegroundColor Red }

# Every command whose output is evidence is printed before it runs, so that a
# claim in the transcript can be checked against the command that produced it.
# This exists because this project has repeatedly been misled by checks that
# could not distinguish "it did not happen" from "I could not look".
function Invoke-Shown {
    param([string] $Exe, [string[]] $Arguments, [switch] $AllowFail)
    Write-Host "  > `"$Exe`" $($Arguments -join ' ')" -ForegroundColor DarkGray
    if ($DryRun) { Write-Host '    (dry run - not executed)' -ForegroundColor DarkGray; return '' }
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "$Exe exited $code"
    }
    return ($out -join "`n")
}

# =============================================================================
# Elevation
# =============================================================================

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

# rpi-imager.exe is manifested requireAdministrator, and writing to a physical
# drive needs it regardless. Rather than failing at the moment of the write -
# after the operator has already moved the jumper and waited - the script asks
# for elevation up front and relaunches itself, forwarding the arguments it was
# given AND the action it was about to run.
#
# THE ACTION HAS TO BE FORWARDED EXPLICITLY, and this is what made an elevated
# run land back on the menu. Chosen from the menu, -Action is never bound: it
# keeps its default 'menu', so it is absent from the invocation and the elevated
# copy has nothing to tell it what the operator picked. It re-drew the menu, the
# operator chose again, and only that second choice ran. Each caller now names
# the action its own window would have run.
function Assert-Elevated {
    param(
        # The -Action the elevated copy must run instead of re-asking. Named by
        # the caller, because only the caller knows what it is doing when the
        # choice came from the menu rather than the command line.
        [Parameter(Mandatory)]
        [ValidateSet('flash', 'render', 'probe', 'cleanup')]
        [string] $ResumeAction
    )
    if (Test-Elevated) { return }

    # `irm <url> | iex` is the shape everyone reaches for, and it CANNOT work
    # here: run that way the script has no file on disk, $PSCommandPath is empty
    # (measured), and there is nothing for the elevated copy to re-invoke. It
    # used to fail inside Start-Process, after the UAC prompt, with the reason
    # invisible. Say it here instead, and say what to do.
    if (-not $PSCommandPath) {
        throw ("This script must be run FROM A FILE, not piped into Invoke-Expression: " +
               "elevation re-invokes it by path and there is no path. Download it first, " +
               "then run it:`n" +
               "    irm $BOOTSTRAP_WIN_URL -OutFile `$env:TEMP\bootstrap_win.ps1; " +
               "powershell -NoProfile -ExecutionPolicy Bypass -File `$env:TEMP\bootstrap_win.ps1")
    }

    # Built before the DryRun test, not after, so that -DryRun PRINTS the exact
    # command line it would launch. The forwarding is the part that was broken;
    # a rehearsal that cannot show it is no rehearsal.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $INVOKED_PARAMS.GetEnumerator()) {
        if ($kv.Key -eq 'Action') { continue }   # replaced by -ResumeAction below
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += "-$($kv.Key)" }
        } else {
            $argList += @("-$($kv.Key)", "`"$($kv.Value)`"")
        }
    }
    $argList += @('-Action', $ResumeAction, '-Relaunched')

    if ($DryRun) {
        Write-Warn2 'not elevated; a real run would relaunch itself as Administrator here, as:'
        Write-Host "      powershell.exe $($argList -join ' ')"
        return
    }
    Write-Step "This step needs Administrator. Relaunching as '$ResumeAction' (accept the UAC prompt)."
    Write-Host "  powershell.exe $($argList -join ' ')"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit 0
}

# =============================================================================
# Install manifest
#
# The manifest answers one question at cleanup time: did THIS script install
# that, or was it already here? It is written BEFORE each install action, never
# reconstructed afterwards, because after the fact the two states are
# indistinguishable - a present rpiboot looks the same whoever put it there.
# oem82.inf is the concrete case: the WinUSB driver on this PC belongs to
# Raspberry Pi Imager, not to us, and removing it would break a tool the
# operator uses for other work. It is recorded as pre-existing and never
# touched.
# =============================================================================

function Read-Manifest {
    if (-not (Test-Path $MANIFEST_PATH)) {
        return [pscustomobject]@{ version = 1; entries = @() }
    }
    $raw = Get-Content -Raw -Path $MANIFEST_PATH -Encoding UTF8
    if (-not $raw.Trim()) { return [pscustomobject]@{ version = 1; entries = @() } }
    return ($raw | ConvertFrom-Json)
}

function Write-Manifest {
    param($Manifest)
    # -DryRun says "touch no disk, install nothing", and the manifest is disk.
    # Writing it anyway also made the rehearsal impossible to run at all: the
    # file belongs to whichever elevated run created it, so an unelevated
    # -DryRun died on "Access to the path ... is denied" before it could show
    # anything. A dry run has to be the cheapest thing in the script to run.
    if ($DryRun) { Write-Host "  (dry run) would record the manifest at $MANIFEST_PATH"; return }
    if (-not (Test-Path $STATE_DIR)) { New-Item -ItemType Directory -Force -Path $STATE_DIR | Out-Null }
    ($Manifest | ConvertTo-Json -Depth 6) | Out-File -FilePath $MANIFEST_PATH -Encoding utf8 -Force
}

# Called immediately BEFORE the install action it describes. $PreExisted is the
# result of the probe taken a moment earlier; if it is true, cleanup will leave
# the thing alone forever after, whatever happens next.
function Register-Install {
    param(
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [bool]   $PreExisted,
        [string] $Path = '',
        [string] $Note = ''
    )
    $m = Read-Manifest
    $entries = @($m.entries | Where-Object { $_.component -ne $Component })
    $entries += [pscustomobject]@{
        component   = $Component
        preExisted  = $PreExisted
        path        = $Path
        note        = $Note
        recordedUtc = (Get-Date).ToUniversalTime().ToString('o')
        installedBy = $(if ($PreExisted) { 'other' } else { 'bootstrap_win.ps1' })
    }
    $m.entries = $entries
    Write-Manifest $m
    Write-Ok "manifest: $Component preExisted=$PreExisted"
}

function Get-ManifestEntry {
    param([string] $Component)
    $m = Read-Manifest
    return ($m.entries | Where-Object { $_.component -eq $Component } | Select-Object -First 1)
}

# =============================================================================
# Probes
#
# Each returns $true/$false and prints the evidence it looked at. A probe that
# cannot look says so and returns $false only when it genuinely established
# absence.
# =============================================================================

function Test-Rpiboot {
    $haveExe    = Test-Path $RPIBOOT_EXE
    $haveGadget = Test-Path (Join-Path $RPIBOOT_GADGET 'boot.img')
    Write-Host "  probe rpiboot.exe          : $haveExe ($RPIBOOT_EXE)"
    Write-Host "  probe mass-storage-gadget64: $haveGadget ($RPIBOOT_GADGET\boot.img)"
    return ($haveExe -and $haveGadget)
}

function Test-Imager {
    $have = Test-Path $IMAGER_EXE
    Write-Host "  probe rpi-imager.exe       : $have ($IMAGER_EXE)"
    return $have
}

function Get-OpenSslPath {
    $candidates = @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files (x86)\Git\usr\bin\openssl.exe'
    )
    $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates = @($cmd.Source) + $candidates }
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

# Fetch the published artefacts. Named separately when they fail, because
# "could not get the token" cannot tell a dead network from a repository that
# stopped serving the file, and those need different actions.
function Get-PublishedBlob {
    try {
        $r = Invoke-WebRequest -Uri $TOKEN_AGE_URL -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "could not fetch the encrypted token from $TOKEN_AGE_URL ($($_.Exception.Message)). Network, or it is not published there."
    }
    $blob = [string]$r.Content
    if ($blob -notmatch 'BEGIN AGE ENCRYPTED FILE') {
        throw "$TOKEN_AGE_URL did not return an age file. Refusing to hand it to age."
    }
    return $blob
}

function Get-PublishedHint {
    try {
        $r = Invoke-WebRequest -Uri $HINT_URL -UseBasicParsing -ErrorAction Stop
        $h = ([string]$r.Content -split "`n")[0].Trim()
        if ($h) { return $h }
    } catch { }
    return "(hint unavailable - $HINT_URL could not be read)"
}

function Get-AgePath {
    $cmd = Get-Command age.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # The copy this script keeps for itself, which is never on PATH.
    if (Test-Path $AGE_EXE) { return $AGE_EXE }
    return $null
}

function Get-GitPath {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # A Git installed in this same session is not on this process' PATH: the
    # installer sets the machine PATH and only new processes inherit it.
    foreach ($c in @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files (x86)\Git\cmd\git.exe')) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# =============================================================================
# Installing what the script needs, rather than refusing
#
# Each one: probe, record whether it pre-existed, download to the cache, verify
# the pinned sha256, install. Verifying before running is not ceremony - these
# are executables fetched over the network and run with the elevation this
# script already holds.
# =============================================================================

function Get-PinnedDownload {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Sha256,
        [Parameter(Mandatory)] [string] $FileName
    )
    if (-not (Test-Path $DEP_DIR)) { New-Item -ItemType Directory -Force -Path $DEP_DIR | Out-Null }
    $path = Join-Path $DEP_DIR $FileName
    if (Test-Path $path) {
        $h = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $Sha256) { Write-Ok "cached $FileName sha256 matches the pin."; return $path }
        Write-Warn2 "cached $FileName does not match the pin - re-downloading."
        Remove-Item -Force $path
    }
    Write-Step "Downloading $FileName"
    Write-Host "  $Url"
    $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $Url -OutFile $path -UseBasicParsing }
    finally { $ProgressPreference = $prev }
    $h = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $Sha256) {
        Remove-Item -Force -ErrorAction SilentlyContinue $path
        throw "$FileName sha256 $h does not match the pinned $Sha256. Refusing to run it."
    }
    Write-Ok "$FileName downloaded and verified against the pin."
    return $path
}

# age ships as a zip with no installer, so it stays in this script's own
# directory and never reaches PATH. Cleanup can delete it without touching
# anything the operator installed for themselves.
function Install-Age {
    $pre = [bool] (Get-Command age.exe -ErrorAction SilentlyContinue)
    Register-Install -Component 'age' -PreExisted $pre -Path $AGE_EXE `
        -Note "age $AGE_VERSION, extracted to this script's own bin; never added to PATH."
    if ($pre)                 { Write-Ok 'age already on PATH - not installing, and cleanup will not remove it.'; return }
    if (Test-Path $AGE_EXE)   { Write-Ok "age already at $AGE_EXE."; return }
    if ($DryRun)              { Write-Host "  (dry run) would download and extract $AGE_URL"; return }
    $zip = Get-PinnedDownload -Url $AGE_URL -Sha256 $AGE_SHA256 -FileName "age-$AGE_VERSION-windows-amd64.zip"
    $tmp = Join-Path $DEP_DIR ('unzip_' + [guid]::NewGuid().ToString('N'))
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $src = Get-ChildItem -Path $tmp -Filter 'age.exe' -Recurse | Select-Object -First 1
        if (-not $src) { throw "no age.exe inside $zip" }
        Copy-Item -Path $src.FullName -Destination $AGE_EXE -Force
    } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp }
    if (-not (Test-Path $AGE_EXE)) { throw "age.exe is still not at $AGE_EXE after extracting." }
    Write-Ok "age $AGE_VERSION installed at $AGE_EXE."
}

# Git for Windows is a system-wide install and the biggest of the three (62 MB).
# It is here because a PC with no checkout needs `git` to fetch one, and because
# `openssl` - which turns the account password into a crypt hash - ships inside
# it. Silent, no restart, no desktop or shell integration.
function Install-Git {
    $pre = [bool] (Get-GitPath)
    Register-Install -Component 'git' -PreExisted $pre -Path 'C:\Program Files\Git' `
        -Note "Git for Windows $GIT_VERSION, silent install; supplies git.exe and openssl.exe."
    if ($pre)    { Write-Ok 'Git already present - not installing, and cleanup will not remove it.'; return }
    if ($DryRun) { Write-Host "  (dry run) would download and silently install $GIT_URL"; return }
    $exe = Get-PinnedDownload -Url $GIT_URL -Sha256 $GIT_SHA256 -FileName "Git-$GIT_VERSION-64-bit.exe"
    Write-Step "Installing Git for Windows $GIT_VERSION (silent)."
    Invoke-Shown $exe @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES',
                        '/COMPONENTS=gitlfs', '/o:PathOption=Cmd') -AllowFail | Out-Null
    if (-not (Get-GitPath)) { throw 'Git is still not present after the installer ran.' }
    Write-Ok "Git for Windows $GIT_VERSION installed."
}

# Imager writes and verifies the card, and it also SHIPS THE WINUSB DRIVER that
# lets rpiboot talk to a board in bootloader mode - so installing it is what
# makes Install-WinUsbDriver find a driver instead of asking the operator to
# add one from Device Manager.
function Install-Imager {
    $pre = Test-Path $IMAGER_EXE
    Register-Install -Component 'imager' -PreExisted $pre -Path $IMAGER_DIR `
        -Note "Raspberry Pi Imager $IMAGER_VERSION, silent install; also supplies rpiboot-winusb.inf."
    if ($pre)    { Write-Ok 'Raspberry Pi Imager already present - not installing, and cleanup will not remove it.'; return }
    if ($DryRun) { Write-Host "  (dry run) would download and silently install $IMAGER_URL"; return }
    $exe = Get-PinnedDownload -Url $IMAGER_URL -Sha256 $IMAGER_SHA256 -FileName "imager_$IMAGER_VERSION.exe"
    Write-Step "Installing Raspberry Pi Imager $IMAGER_VERSION (silent)."
    Invoke-Shown $exe @('/quiet', '/norestart') -AllowFail | Out-Null
    if (-not (Test-Path $IMAGER_EXE)) { throw "Raspberry Pi Imager is still not at $IMAGER_EXE after the installer ran." }
    Write-Ok "Raspberry Pi Imager $IMAGER_VERSION installed."
}

# The three, in the order the script needs them: age and git BEFORE anything
# tries to read a checkout or decrypt a token, Imager before the write.
function Install-Dependencies {
    Write-Step 'Dependencies: installing whatever this PC is missing.'
    Install-Age
    Install-Git
    Install-Imager
}

# =============================================================================
# Kernel reconciliation
#
# Every deploy compiles kernel modules against the running kernel, so
# host/kernel/SUPPORTED_KERNELS is an allowlist and setup_host.sh refuses a
# kernel that is not on it. The image this script writes therefore decides
# whether the deploy can succeed at all. This REPORTS a mismatch; it must never
# widen the allowlist, because the allowlist exists precisely because our own
# deploy was silently bumping the host kernel underneath us (J8).
# =============================================================================

function Test-KernelAllowlist {
    param([string] $Root)
    $f = Join-Path $Root 'host\kernel\SUPPORTED_KERNELS'
    if (-not (Test-Path $f)) {
        Write-Warn2 "SUPPORTED_KERNELS not found at $f - kernel NOT reconciled."
        return $false
    }
    $allowed = @(Get-Content $f | ForEach-Object { ($_ -replace '#.*$', '').Trim() } | Where-Object { $_ })
    Write-Host "  image kernel (CM4)  : $IMAGE_KERNEL_V8"
    Write-Host "  allowlist ($f):"
    $allowed | ForEach-Object { Write-Host "      $_" }
    if ($allowed -contains $IMAGE_KERNEL_V8) {
        Write-Ok "image kernel $IMAGE_KERNEL_V8 is on the allowlist."
        return $true
    }
    Write-Bad "image kernel $IMAGE_KERNEL_V8 is NOT on the allowlist."
    Write-Host '       Do not widen the allowlist to make this pass. Validate the kernel on a'
    Write-Host '       bench (UVC stream + still + both module builds green), then add it and'
    Write-Host '       commit - host/kernel/README.md, "Changing the pinned kernel".'
    return $false
}

# =============================================================================
# Credentials
#
# THE RULE: no plaintext password on this PC, at any point, in any file. That is
# achievable only because a crypt hash is not a plaintext - it is a one-way
# function of one, and it is what /etc/shadow holds anyway.
#
# The chain, in order, and why it is that order:
#   1. Raspberry Pi Imager's own registry value. Imager never stores the
#      plaintext either - the value there is already a crypt hash - so reusing
#      it costs nothing and stores nothing new. On this PC it is a yescrypt hash
#      ($y$jB5$...), which is the trixie image's OWN native format: that image
#      sets ENCRYPT_METHOD YESCRYPT in /etc/login.defs and its
#      libcrypt.so.1.1.0 exports the yescrypt hashes (both read out of the
#      mounted image on 2026-09-05, see the session log). cloud-init hands the
#      value to `chpasswd -e` unchanged, so no conversion is involved and none
#      is possible.
#   2. Our own stored hash, from a previous run.
#   3. A hidden prompt, hashed locally with `openssl passwd -6` (SHA-512, also
#      accepted by trixie). The plaintext is read into a SecureString and the
#      unmanaged copy is freed in the same scope that read it.
#
# Ask once, reuse thereafter: on a later run nothing is asked at all, and that
# is only offerable because step 2 exists.
# =============================================================================

function Get-ImagerRegValue {
    param([string] $Name)
    try {
        $p = Get-ItemProperty -Path $IMAGER_REG -Name $Name -ErrorAction Stop
        return [string] $p.$Name
    } catch {
        return $null
    }
}

function ConvertTo-PlainText {
    param([Security.SecureString] $Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-PasswordHash {
    $fromReg = Get-ImagerRegValue 'sshUserPassword'
    if ($fromReg -and $fromReg.StartsWith('$')) {
        $prefix = $fromReg.Substring(0, [Math]::Min(7, $fromReg.Length))
        Write-Ok "password hash reused from Raspberry Pi Imager ($prefix..., $($fromReg.Length) chars)."
        return $fromReg
    }
    if (Test-Path $HASH_PATH) {
        $stored = (Get-Content -Raw -Path $HASH_PATH).Trim()
        if ($stored) {
            Write-Ok "password hash reused from $HASH_PATH."
            return $stored
        }
    }
    $ssl = Get-OpenSslPath
    if (-not $ssl) {
        throw 'No password hash available and openssl.exe was not found (looked in Git for Windows). Install Git for Windows, or set the password in Raspberry Pi Imager once.'
    }
    Write-Host ''
    Write-Host 'No stored password hash. Choose the node account password (input hidden).'
    Write-Host 'It is hashed here and discarded immediately; only the hash is kept.'
    $sec = Read-Host -AsSecureString '  password'
    $plain = ConvertTo-PlainText $sec
    if (-not $plain) { throw 'Empty password.' }
    # -stdin keeps the password off the command line, so it never appears in the
    # process table for the moment openssl runs.
    $hash = (($plain | & $ssl passwd -6 -stdin) -join '').Trim()
    $plain = $null
    [GC]::Collect()
    if (-not $hash.StartsWith('$6$')) {
        throw "openssl produced something that is not a SHA-512 crypt hash: '$hash'"
    }
    if (-not (Test-Path $STATE_DIR)) { New-Item -ItemType Directory -Force -Path $STATE_DIR | Out-Null }
    $hash | Out-File -FilePath $HASH_PATH -Encoding ascii -Force
    Write-Ok "hash stored in $HASH_PATH (the password itself was never written anywhere)."
    return $hash
}

# Public keys, not secrets - but the same ask-once-then-remember rule, because
# the point is that a normal run asks for nothing.
function Get-AuthorizedKeys {
    $fromReg = Get-ImagerRegValue 'sshAuthorizedKeys'
    if ($fromReg) {
        $keys = @($fromReg -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($keys.Count -gt 0) {
            Write-Ok "$($keys.Count) authorized key(s) from Raspberry Pi Imager."
            return $keys
        }
    }
    if (Test-Path $KEYS_PATH) {
        $keys = @(Get-Content $KEYS_PATH | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($keys.Count -gt 0) {
            Write-Ok "$($keys.Count) authorized key(s) from $KEYS_PATH."
            return $keys
        }
    }
    # Fallback: an existing node's authorized_keys. Read-only, and it fails
    # loudly rather than producing a node nobody can log into.
    Write-Warn2 'No keys in the Imager registry and none stored. Falling back to glnode7 (read-only).'
    $out = & ssh.exe -o BatchMode=yes -o ConnectTimeout=10 'pi@192.168.0.207' 'cat ~/.ssh/authorized_keys' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read authorized_keys from pi@192.168.0.207 (ssh exited $LASTEXITCODE): $out -- set the keys once in Raspberry Pi Imager, or write them to $KEYS_PATH."
    }
    $keys = @($out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($keys.Count -eq 0) { throw 'glnode7 returned no authorized keys.' }
    if (-not (Test-Path $STATE_DIR)) { New-Item -ItemType Directory -Force -Path $STATE_DIR | Out-Null }
    $keys | Out-File -FilePath $KEYS_PATH -Encoding ascii -Force
    Write-Ok "$($keys.Count) key(s) read from glnode7 and stored in $KEYS_PATH."
    return $keys
}

# =============================================================================
# The deploy passphrase
#
# WHERE IT IS TYPED, AND WHY IT CANNOT BE ANYWHERE ELSE
#   The clone token is age-encrypted with a passphrase that exists only in the
#   owner's head. Nothing in this flow can supply it, so it is typed once, and
#   that is the only interactive moment in the whole provisioning path. It is
#   typed at AGE'S prompt, not at one of ours: this script never receives it,
#   stores it, or writes it anywhere, and what goes on the card is the clone
#   token age produced (/boot/firmware/scanbox-deploy.token), which the node
#   moves to tmpfs and shreds in the first seconds of first boot
#   (host/cloudinit/provision.sh.tmpl, step 1).
#
# WHY THE TOKEN AND NOT THE PASSPHRASE
#   The blob is PUBLISHED - that is what a public entry point means.
#   So a card carrying the passphrase carries every token that blob will ever
#   hold, for every node, unrevocably. A card carrying the token carries one
#   read-only, single-repo credential that GitHub revokes in a click and that
#   expires on its own. Both are secrets in transit; only one is the master key.
#
# AND IT IS VERIFIED, WHICH IT WAS NOT BEFORE
#   This note used to say verification was impossible from PowerShell, because
#   age reads a passphrase from the terminal and nowhere else - measured, not
#   assumed (age 1.1.1 on Linux and 1.3.1 here, 2026-09-05): with stdin
#   redirected it does not fall back to stdin, it fails with "standard input is
#   not a terminal". That is true of a child created with NO CONSOLE. This
#   script runs in one, which is why the standalone clone path below has always
#   been able to do it. A successful decrypt IS the verification, so a wrong
#   passphrase is caught here in a second instead of on a node twenty minutes
#   later.
# =============================================================================

# Open the blob HERE and put the TOKEN on the card, not the passphrase.
#
# WHY, and it is not about how either one works. The blob bootstrap_node.sh fetches is
# published on purpose - it is the whole point of a public entry point. So a
# card carrying the master passphrase carries every token that blob will ever
# hold, for every node, and revoking it means rotating everything. A card
# carrying the token carries one read-only, single-repo credential that GitHub
# revokes in a click and that expires on its own. Both are secrets in transit;
# only one of them is the master key.
#
# Two consequences fall out of doing it here rather than on the node.
#
#   The passphrase never enters this process. age prompts for it against the
#   real console and reads it from /dev/tty (a console handle here); PowerShell
#   never sees it, so there is no immutable .NET string of it left on the heap
#   for a garbage collector to maybe overwrite. The old prompt could not say
#   that.
#
#   It IS verified. The note above this function used to say verification was
#   impossible from PowerShell, and that was right about a child created with no
#   console - but this script runs in one. A successful decrypt is the check,
#   and a wrong passphrase is now caught on the PC in a second instead of
#   surfacing on a node twenty minutes later.
# ONE PROMPT PER RUN, AND THIS FUNCTION OWNS IT.
#
# Two callers need the same token: Get-SparseCheckout, to clone the three
# directories this script reads when the PC has no checkout, and Invoke-Flash,
# for the copy that goes on the card. They are the SAME credential out of the
# SAME published blob, so decrypting twice asks the operator for the same
# passphrase twice - which is what a real run did, right after the file header
# claims it is "asked for ONCE".
#
# It is cached here rather than passed around because the alternative is
# threading it through Resolve-RepoRoot, which has no business holding a
# credential. The value already lives in this process until the seed is written;
# caching it changes when it is discarded, not whether.
$script:DEPLOY_TOKEN = $null

function Get-DeployToken {
    if ($script:DEPLOY_TOKEN) {
        Write-Ok 'deploy token already unlocked earlier in this run - not asking again.'
        return $script:DEPLOY_TOKEN
    }
    $age = Get-AgePath
    if (-not $age) {
        throw ('age.exe not found, and it is what turns the passphrase into the token that ' +
               'goes on the card. Install-Age should have put it there, so reaching this ' +
               'means the install failed or was skipped - re-run, or use -NoPassphrase to ' +
               'write a card with no credential at all and run bootstrap by hand.')
    }
    $blob = Join-Path $env:TEMP ('sbxblob_' + [guid]::NewGuid().ToString('N') + '.age')
    [IO.File]::WriteAllText($blob, (Get-PublishedBlob), (New-Object Text.UTF8Encoding($false)))
    try {
        Write-Host ''
        Write-Host 'Deploy passphrase (the only thing this script asks you for).' -ForegroundColor Yellow
        Write-Host "  hint: $(Get-PublishedHint)" -ForegroundColor Yellow
        Write-Host '  age asks for it at ITS OWN prompt below - this script never sees it.'
        Write-Host '  A successful decrypt is also the check that it was the right one.'
        $token = (& $age -d $blob) -join ''
        if ($LASTEXITCODE -ne 0 -or -not $token) {
            throw 'age could not decrypt the clone token (wrong passphrase?). Nothing was written.'
        }
        Write-Ok 'passphrase accepted; the card will carry the clone token, not the passphrase.'
        $script:DEPLOY_TOKEN = $token
        return $token
    } finally {
        Remove-Item -Force -ErrorAction SilentlyContinue $blob
    }
}

# =============================================================================
# Repo source
#
# bootstrap_win.ps1 reads exactly three directories: host/cloudinit (the templates),
# host/profiles (the per-node facts) and host/kernel (the allowlist). Cloning
# the whole repository to read three directories is both slow and more than this
# script is entitled to, so the standalone path uses a blobless, cone-mode
# sparse checkout.
#
# When bootstrap_win.ps1 is run from inside a checkout - which is how it is used during
# development and how the owner will normally run it - that checkout is used and
# nothing is cloned or downloaded at all.
# =============================================================================

function Find-LocalCheckout {
    if ($RepoRoot) {
        if (Test-Path (Join-Path $RepoRoot 'host\cloudinit')) { return (Resolve-Path $RepoRoot).Path }
        throw "-RepoRoot $RepoRoot does not look like a scanbox checkout (no host\cloudinit)."
    }
    $d = Split-Path -Parent $PSCommandPath
    for ($i = 0; $i -lt 5 -and $d; $i++) {
        if ((Test-Path (Join-Path $d 'host\cloudinit')) -and (Test-Path (Join-Path $d 'host\profiles'))) {
            return $d
        }
        $d = Split-Path -Parent $d
    }
    return $null
}

function Get-SparseCheckout {
    $git = Get-GitPath
    if (-not $git) { throw 'git.exe not found. Install Git for Windows.' }
    $age = Get-AgePath
    if (-not $age) { throw 'age.exe not found, and it is needed to decrypt the clone token. Install-Age should have provided it; re-run -Action flash, which installs dependencies first.' }

    Write-Step 'No local checkout - fetching the three directories this script reads.'
    # The same credential the card gets, from the same blob. Get-DeployToken owns
    # the prompt and caches it, so a run that needs it here and again for the
    # card asks once - which is what the header of this file has always claimed.
    $token = Get-DeployToken
    $tokFile = $null
    $askFile = $null
    try {
        if (Test-Path $CLONE_DIR) { Remove-Item -Recurse -Force $CLONE_DIR }
        New-Item -ItemType Directory -Force -Path $CLONE_DIR | Out-Null

        # THE TOKEN DOES NOT GO IN THE URL. It used to, with a comment saying the
        # remote was temporary - which addressed where the credential was STORED
        # and not where it was SHOWN. Invoke-Shown prints every command it runs,
        # so that clone printed the token in cleartext to the console and into
        # any transcript of the run. bootstrap_node.sh has never done this: it feeds
        # git through an askpass shim precisely so the credential reaches no
        # command line. This is the same shim, in the other language.
        #
        # Two temporary files, both in the user's own TEMP, both removed in the
        # finally below whatever happens: one holds the token, one is the shim
        # that prints it. git calls the shim with a prompt string and takes one
        # line of its output - "Username" gets the fixed account name that
        # GitHub tokens use, anything else gets the token itself.
        # THE SHIM IS A /bin/sh SCRIPT, NOT A .cmd, and that is not a style
        # choice. Git cannot execute a .cmd as GIT_ASKPASS: it fails with
        # "Access is denied" and the shim never runs at all, which surfaced as
        # `fatal: unable to get password from user` on a real launch. Measured
        # both ways on this PC - the .cmd never ran, an identical /bin/sh script
        # ran and its answer reached GitHub. Git for Windows ships the sh that
        # runs it, and bootstrap_node.sh has always used this shape.
        #
        # LF line endings and a forward-slash path, both required: CRLF breaks
        # the shebang line, and sh does not read `C:\...`.
        $tokFile = Join-Path $env:TEMP ('sbxtok_' + [guid]::NewGuid().ToString('N') + '.txt')
        $askFile = Join-Path $env:TEMP ('sbxask_' + [guid]::NewGuid().ToString('N') + '.sh')
        [IO.File]::WriteAllText($tokFile, $token, (New-Object Text.UTF8Encoding($false)))
        # Owner-only, so another account on this PC cannot read it while it exists.
        & icacls.exe $tokFile /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null
        $tokForSh = $tokFile -replace '\\', '/'
        $shim = "#!/bin/sh`n" +
                "case `"`$1`" in`n" +
                "  *sername*) echo `"x-access-token`" ;;`n" +
                "  *)         cat `"$tokForSh`" ;;`n" +
                "esac`n"
        [IO.File]::WriteAllText($askFile, $shim, (New-Object Text.UTF8Encoding($false)))
        $token = $null
        [GC]::Collect()

        $url = 'https://github.com/Alkaronyan/scanbox.git'
        $env:GIT_ASKPASS = $askFile
        $env:GIT_TERMINAL_PROMPT = '0'

        # GIT_ASKPASS IS NOT ENOUGH ON WINDOWS, and this is what a real run hit:
        # Git for Windows writes `credential.helper = manager` into its own
        # system gitconfig, and git asks the HELPER before it ever reaches
        # askpass. Git Credential Manager then opens its GUI sign-in window and
        # the run stops dead - on a PUBLIC-looking one-liner, at a private repo
        # nobody said would need a login. Measured on this PC:
        #   git config --show-origin --get-all credential.helper
        #   file:C:/Program Files/Git/etc/gitconfig    manager
        #
        # An EMPTY value resets the helper chain for this invocation only
        # (verified: `git -c credential.helper= config --get-all
        # credential.helper` prints the inherited one and then an empty line),
        # so askpass is the only thing left that can answer. Nothing on the PC
        # is changed: no --global, no --system, no stored credential.
        #
        # `credential.interactive=false` was here too and is deliberately NOT:
        # it MASKED the next defect. With it, git's failure to execute the shim
        # read as `unable to get password from user`; without it, the same run
        # says `Access is denied`, which is what pointed at the shim itself.
        $noHelper = @('-c', 'credential.helper=')
        Invoke-Shown $git ($noHelper + @('clone', '--quiet', '--filter=blob:none', '--no-checkout', '--depth', '1', '--branch', $REPO_BRANCH, $url, $CLONE_DIR)) | Out-Null
        Invoke-Shown $git ($noHelper + @('-C', $CLONE_DIR, 'sparse-checkout', 'set', '--cone', 'host/cloudinit', 'host/profiles', 'host/kernel')) | Out-Null
        # This one reaches the network too: the clone was --filter=blob:none, so
        # the checkout is what actually fetches the file contents. It needs the
        # same askpass, and the same helper chain cleared.
        Invoke-Shown $git ($noHelper + @('-C', $CLONE_DIR, 'checkout', '--quiet')) | Out-Null
        # No set-url is needed any more: the remote was never written with a
        # credential in it, so there is nothing in .git/config to undo.
        Write-Ok "sparse checkout at $CLONE_DIR (the token reached git through an askpass shim, never a URL)"
        Invoke-Shown $git @('-C', $CLONE_DIR, 'sparse-checkout', 'list') | Out-Null
        return $CLONE_DIR
    } finally {
        # No $blob here any more: Get-DeployToken owns the encrypted file and
        # removes its own. Referencing it would throw under Set-StrictMode.
        if ($tokFile) { Remove-Item -Force -ErrorAction SilentlyContinue $tokFile }
        if ($askFile) { Remove-Item -Force -ErrorAction SilentlyContinue $askFile }
        Remove-Item -Force -ErrorAction SilentlyContinue Env:\GIT_ASKPASS
        Remove-Item -Force -ErrorAction SilentlyContinue Env:\GIT_TERMINAL_PROMPT
    }
}

function Resolve-RepoRoot {
    $local = Find-LocalCheckout
    if ($local) {
        Write-Ok "using the local checkout at $local (nothing cloned)."
        return $local
    }
    return (Get-SparseCheckout)
}

# =============================================================================
# Node profile
#
# Per-board facts come from host/profiles/<serial>.env and from nowhere else.
# That is the same rule the deploy already follows, and it is the reason
# timezone is NOT taken from Raspberry Pi Imager: Imager holds Europe/Zurich,
# which is where the PC is, and the rig runs Europe/Paris. A board fact belongs
# with the board.
#
# ONE profile is loaded and it is not layered over default.env - see
# host/profiles/README.md. The reader below mirrors that: it looks up
# <serial>.env, or default.env, never both.
# =============================================================================

function Read-NodeProfile {
    param([string] $Root, [string] $BoardSerial)
    $dir = Join-Path $Root 'host\profiles'
    $file = $null
    if ($BoardSerial) {
        $candidate = Join-Path $dir "$BoardSerial.env"
        if (Test-Path $candidate) {
            $file = $candidate
        } else {
            Write-Warn2 "no profile for serial '$BoardSerial' at $candidate."
            Write-Warn2 'Falling back to default.env. That node will get the safe minimal'
            Write-Warn2 'configuration and will NOT get its hostname, timezone or network.'
            Write-Warn2 "Add host/profiles/$BoardSerial.env and re-run - see host/profiles/README.md."
        }
    }
    if (-not $file) { $file = Join-Path $dir 'default.env' }
    if (-not (Test-Path $file)) { throw "No profile at $file" }
    Write-Ok "profile: $file"

    $values = @{}
    foreach ($line in Get-Content $file) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $m = [regex]::Match($t, '^(?<k>[A-Za-z_][A-Za-z0-9_]*)=(?<v>.*)$')
        if (-not $m.Success) { continue }
        $v = $m.Groups['v'].Value.Trim()
        if ($v.Length -ge 2 -and (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'")))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $values[$m.Groups['k'].Value] = $v
    }
    return [pscustomobject]@{ Path = $file; Values = $values }
}

function Get-ProfileValue {
    param($Profile, [string] $Key, [string] $Default = '')
    if ($Profile.Values.ContainsKey($Key)) {
        $v = [string] $Profile.Values[$Key]
        if ($v) { return $v }
    }
    return $Default
}

# =============================================================================
# Seed rendering
# =============================================================================

function Expand-Template {
    param([string] $Path, [hashtable] $Map)
    $text = [IO.File]::ReadAllText($Path)
    foreach ($k in $Map.Keys) {
        $text = $text.Replace('@@' + $k + '@@', [string] $Map[$k])
    }
    $left = [regex]::Matches($text, '@@[A-Z0-9_]+@@')
    if ($left.Count -gt 0) {
        $names = ($left | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '
        throw "Template $Path still has unsubstituted placeholders: $names"
    }
    return $text
}

# Everything the seed needs, gathered in one place so the render is a pure
# function of it and can be produced with no board attached (Action 'render').
function New-SeedContext {
    param([string] $Root, [string] $BoardSerial)

    $nodeProfile = Read-NodeProfile -Root $Root -BoardSerial $BoardSerial
    $stamp   = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')

    $user = Get-ImagerRegValue 'sshUserName'
    if (-not $user) { $user = 'pi' }
    $kbd = Get-ImagerRegValue 'keyboard'
    if (-not $kbd) { $kbd = 'us' }
    $pwAuthRaw = Get-ImagerRegValue 'sshPasswordAuth'
    $pwAuth = 'false'
    if ($pwAuthRaw -and $pwAuthRaw.Trim().ToLower() -eq 'true') { $pwAuth = 'true' }

    $hostname = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_HOSTNAME' ''
    if (-not $hostname) {
        if ($BoardSerial) { $hostname = 'scanbox-' + $BoardSerial.Substring([Math]::Max(0, $BoardSerial.Length - 8)) }
        else { $hostname = 'scanbox-unnamed' }
        Write-Warn2 "profile states no SCANBOX_NODE_HOSTNAME; using '$hostname'."
    }
    $timezone = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_TIMEZONE' 'Etc/UTC'
    if ($timezone -eq 'Etc/UTC') { Write-Warn2 'profile states no SCANBOX_NODE_TIMEZONE; using Etc/UTC.' }

    $iface   = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_NET_IFACE'   'eth0'
    $addr    = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_NET_ADDRESS' ''
    $gateway = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_NET_GATEWAY' ''
    $dns     = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_NET_DNS'     ''
    $branch  = Get-ProfileValue $nodeProfile 'SCANBOX_NODE_DEPLOY_BRANCH' $REPO_BRANCH

    if ($addr) {
        $lines = @('      dhcp4: false', "      addresses: [$addr]")
        if ($gateway) { $lines += @('      routes:', '        - to: default', "          via: $gateway") }
        if ($dns) {
            $list = (($dns -split '[,\s]+' | Where-Object { $_ }) -join ', ')
            $lines += @('      nameservers:', "        addresses: [$list]")
        }
        $netBlock = ($lines -join "`n")
    } else {
        $netBlock = '      dhcp4: true'
    }

    $keys = Get-AuthorizedKeys
    $keyBlock = (($keys | ForEach-Object { '  - ' + $_ }) -join "`n")
    # The same keys again, indented for the per-user list inside `users:`.
    # One source, two indentations - never two lists to keep in step.
    $keyBlockUser = (($keys | ForEach-Object { '      - ' + $_ }) -join "`n")

    return [pscustomobject]@{
        Profile = $nodeProfile
        Map = @{
            HOSTNAME           = $hostname
            TIMEZONE           = $timezone
            KEYBOARD_LAYOUT    = $kbd
            SSH_USER           = $user
            SSH_PWHASH         = (Get-PasswordHash)
            SSH_PWAUTH         = $pwAuth
            SSH_AUTHORIZED_KEYS = $keyBlock
            SSH_AUTHORIZED_KEYS_USER = $keyBlockUser
            INSTANCE_ID        = "scanbox-$hostname-$stamp"
            NET_IFACE          = $iface
            NET_ADDRESSING     = $netBlock
            BOOTSTRAP_URL      = $BOOTSTRAP_URL
            REPO_BRANCH        = $branch
            RENDER_STAMP       = $stamp
            PROFILE_NAME       = (Split-Path -Leaf $nodeProfile.Path)
        }
    }
}

# Writes user-data, meta-data, network-config and scanbox-provision.sh as LF
# text with no BOM. Both matter: cloud-init parses YAML, and a UTF-8 BOM on the
# first line of user-data makes it fail to recognise the '#cloud-config' header;
# and the provision script is run by bash, which treats a CR as part of a
# filename.
function Write-Seed {
    param([string] $Root, $Ctx, [string] $Destination, [string] $Token)

    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
    $tdir = Join-Path $Root 'host\cloudinit'
    $enc  = New-Object Text.UTF8Encoding($false)
    $written = @()

    # ENABLE SSHD. The seed lists authorized keys, which configures WHO may log
    # in, and says nothing about whether the service runs at all - and on
    # Raspberry Pi OS it does not. sshd stays off until this marker exists on
    # the boot partition; `sshswitch.service` reads it at boot, enables ssh and
    # deletes the file. Imager's own customisation writes it, which is why a
    # card made by hand behaves and one made by this script did not.
    #
    # Without it the node comes up on the network, answers ICMP, runs its whole
    # unattended deploy - and cannot be reached, inspected or rescued. Measured
    # on glnode7's first flash, 2026-09-06: ICMP up, every TCP port closed
    # including 22.
    #
    # An empty file, written unconditionally: harmless on an image where ssh is
    # already enabled, and the difference between a node and a brick otherwise.
    # Appended as the PATH, like every other entry. It was first written as
    # `,@('ssh', 0)` - a nested array among strings - and the read-back below
    # then called Get-Item on the two-element array, which PowerShell resolved
    # as the relative path 'ssh' against the elevated process' working
    # directory (C:\WINDOWS\system32) and threw. The card was complete and
    # correct; the run died reporting on it. Same scalar-vs-array trap as the
    # serial parse, in the fix for the missing marker.
    $sshMarker = Join-Path $Destination 'ssh'
    [IO.File]::WriteAllText($sshMarker, '', $enc)
    $written += $sshMarker

    foreach ($pair in @(
        @('user-data.tmpl',      'user-data'),
        @('meta-data.tmpl',      'meta-data'),
        @('network-config.tmpl', 'network-config'),
        @('provision.sh.tmpl',   'scanbox-provision.sh'))) {

        $src = Join-Path $tdir $pair[0]
        $dst = Join-Path $Destination $pair[1]
        if (-not (Test-Path $src)) { throw "Missing template $src" }
        $text = (Expand-Template -Path $src -Map $Ctx.Map) -replace "`r`n", "`n"
        if ($DryRun) { Write-Host "  (dry run) would write $dst"; continue }
        [IO.File]::WriteAllText($dst, $text, $enc)
        $written += $dst
    }

    if ($Token) {
        $dst = Join-Path $Destination 'scanbox-deploy.token'
        if ($DryRun) {
            Write-Host "  (dry run) would write $dst"
        } else {
            [IO.File]::WriteAllText($dst, ($Token + "`n"), $enc)
            $written += $dst
        }
    }

    # Read back what was written. A write that silently produced nothing is the
    # exact failure this repo keeps meeting, so the sizes are printed from the
    # filesystem rather than from what we believe we wrote.
    foreach ($f in $written) {
        $len = (Get-Item $f).Length
        $label = Split-Path -Leaf $f
        if ($label -eq 'scanbox-deploy.token') {
            Write-Ok ("wrote {0} ({1} bytes, contents not shown)" -f $label, $len)
        } else {
            Write-Ok ("wrote {0} ({1} bytes)" -f $label, $len)
        }
    }
    return $written
}

# =============================================================================
# The board
# =============================================================================

# Is a gadget-exposed eMMC already attached? IDENTIFY THE THING BY WHAT IT IS.
#
# A board sitting in mass-storage mode is the ordinary state after any previous
# run of this script, after a failed one, and after an operator has used rpiboot
# by hand. In that state it presents PID_0104 and NOT the bootloader's PID_27xx,
# so Wait-ForBootloader below waits out its whole timeout for a device that
# cannot appear, and then throws telling the operator to check a jumper that is
# fitted correctly. Wait-ForMassStorage already knew how to recognise the gadget
# by its signature; the wait in front of it did not, and that gap is the bug.
function Get-GadgetEmmc {
    $d = @(Get-WmiObject Win32_DiskDrive |
           Where-Object { $_.InterfaceType -eq 'USB' -and
                          ([string]$_.Model -match 'mmcblk') -and
                          ([string]$_.PNPDeviceID -match '^USBSTOR\\') })
    if ($d.Count -eq 1) { return $d[0] }
    return $null
}

# The CM4 in nRPIBOOT mode presents Broadcom's bootloader VID/PID. Waiting for
# THAT, rather than for a keypress, is what lets the script tell the operator
# one instruction at a time and know when it has been carried out.
function Wait-ForBootloader {
    param([int] $TimeoutSeconds = 300)
    Write-Host ''
    Write-Host '  ACTION: with the board powered OFF, fit the nRPIBOOT jumper' -ForegroundColor Yellow
    Write-Host '          (CM4 IO board: J2 "Fit jumper to disable eMMC boot"),' -ForegroundColor Yellow
    Write-Host '          connect the USB-C slave port to this PC, then power it on.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Waiting for the board to appear (no keypress needed)...'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $dev = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                 Where-Object { $_.InstanceId -like 'USB\VID_0A5C&PID_27*' })
        if ($dev.Count -gt 0) {
            foreach ($d in $dev) { Write-Ok "found $($d.InstanceId) - $($d.FriendlyName)" }
            return $dev[0]
        }
        Start-Sleep -Seconds 2
    }
    throw "No Raspberry Pi bootloader device appeared within $TimeoutSeconds s. Check the jumper, the USB-C cable (it must be the SLAVE port), and power."
}

# rpiboot loads the gadget in TWO stages and the gap between them is a race it
# loses by default on Windows. Stage one sends bootcode4.bin; the device then
# re-enumerates, and rpiboot must open it again to send boot.img. Its device
# poll defaults to 500 microseconds (`-m 500`), which is far shorter than
# Windows takes to finish enumerating the re-appeared device and bind its
# driver, so the second open lands on a half-built device and rpiboot exits 255
# with `Failed to read config descriptor`.
#
# Measured on glnode7, 2026-09-06: with the default poll it failed on that line
# every time; with `-m 1000000` (one second) it completed the second stage on
# the first attempt, and the eMMC appeared as mmcblk0.
#
# The retry loop is not belt-and-braces on top of that: the widened poll makes
# the race unlikely, not impossible, and a retry costs two seconds against an
# operator who has already moved a jumper. What was NOT acceptable is the
# previous shape - one attempt, -AllowFail, and no inspection of the exit code -
# which turned rpiboot's own loud failure into a silent one and left the script
# waiting out the whole mass-storage timeout for a disk that was never coming.
# A failure here is now reported as a failure, and only after it has been tried.
function Invoke-Rpiboot {
    param([int] $Attempts = 5)
    if ($DryRun) {
        Write-Host "  (dry run) would run: `"$RPIBOOT_EXE`" -v -m 1000000 -d `"$RPIBOOT_GADGET`""
        return
    }
    for ($i = 1; $i -le $Attempts; $i++) {
        Write-Host ("  rpiboot attempt {0} of {1}" -f $i, $Attempts)
        Write-Host "  > `"$RPIBOOT_EXE`" -v -m 1000000 -d `"$RPIBOOT_GADGET`"" -ForegroundColor DarkGray
        $out  = & $RPIBOOT_EXE -v -m 1000000 -d $RPIBOOT_GADGET 2>&1
        $code = $LASTEXITCODE
        if ($out) { $out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
        # EXIT 0 IS NOT SUCCESS HERE, and believing it cost a whole run.
        # Measured 2026-09-06: rpiboot printed "Failed control transfer" and
        # "Failed to write complete file to USB device" while sending boot.img,
        # and STILL exited 0. The gadget never loaded, so the mass-storage wait
        # after this spent its full 180 s on a disk that could not appear, and
        # then blamed the jumper - which was fitted, and correct. Same shape as
        # the defect this function was written for: trusting the code over the
        # output. The success line is the evidence; the exit code is a hint.
        $said_done = ($out -join "`n") -match 'Second stage boot server done'
        $said_fail = ($out -join "`n") -match 'Failed to write complete file|Failed control transfer'
        if ($code -eq 0 -and $said_done -and -not $said_fail) {
            Write-Ok "rpiboot completed the second stage (attempt $i)."
            return
        }
        if ($code -eq 0) {
            Write-Warn2 ("rpiboot exited 0 on attempt $i but did not say it finished" +
                         $(if ($said_fail) { " - it reported a failed transfer" } else { "" }) + ".")
        } else {
            Write-Warn2 "rpiboot exited $code on attempt $i."
        }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    throw ("rpiboot failed $Attempts times. Its last exit code is above. If it says " +
           "'Failed to read config descriptor', the board is re-enumerating faster than " +
           "Windows can bind it - power-cycle the board with the jumper still fitted and re-run.")
}

# After rpiboot has loaded the mass-storage gadget the eMMC shows up as a USB
# disk. Its PNPDeviceID carries the board serial, which is what selects the node
# profile - so it is READ, printed, and never guessed at.
# IDENTIFY THE DISK BY WHAT IT IS, NOT BY WHEN IT APPEARED.
#
# This used to wait for a disk that was not in a snapshot taken before rpiboot
# ran. That works exactly once. A board already sitting in mass-storage mode -
# because a previous attempt left it there, which is the normal state after any
# failed run - is in the snapshot, so no "new" disk ever appears and the script
# waits out its whole timeout on a machine where the eMMC is plugged in and
# visible. Hit on the first real flash of glnode7, 2026-09-06: `Get-WmiObject
# Win32_DiskDrive` showed PHYSICALDRIVE1 'mmcblk0 USB Device' 14.6 GB while this
# function was still printing "Waiting for the eMMC to appear".
#
# So: a new disk is preferred, because on a cold board that is the least
# ambiguous signal. When none appears, fall back to recognising the gadget by
# its signature - a USB disk whose model names mmcblk and whose PNPDeviceID is
# USBSTOR. Either way, more than one candidate is a refusal and never a guess.
function Wait-ForMassStorage {
    param([string[]] $KnownDiskIds, [int] $TimeoutSeconds = 180)
    Write-Host '  Waiting for the eMMC to appear as a USB disk...'

    function Show-Disk($d) {
        Write-Ok ("disk {0}  model='{1}'  size={2:N1} GB" -f $d.DeviceID, $d.Model, ($d.Size / 1GB))
        Write-Host "       PNPDeviceID: $($d.PNPDeviceID)"
    }
    function Test-IsGadgetEmmc($d) {
        return ([string]$d.Model -match 'mmcblk') -and ([string]$d.PNPDeviceID -match '^USBSTOR\\')
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $disks = @(Get-WmiObject Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' })
        $new = @($disks | Where-Object { $KnownDiskIds -notcontains $_.DeviceID })
        if ($new.Count -gt 0) {
            foreach ($d in $new) { Show-Disk $d }
            if ($new.Count -gt 1) {
                throw "More than one new USB disk appeared. Refusing to choose - unplug the others and re-run."
            }
            return $new[0]
        }
        # Nothing new. Was it already there? Only accept something that looks
        # like the gadget, so an unrelated USB stick can never be selected.
        $already = @($disks | Where-Object { Test-IsGadgetEmmc $_ })
        if ($already.Count -eq 1) {
            Write-Host '  no NEW disk appeared - the board was already in mass-storage mode.'
            Show-Disk $already[0]
            return $already[0]
        }
        if ($already.Count -gt 1) {
            throw ("Several USB disks look like a gadget-exposed eMMC (" +
                   (($already | ForEach-Object { $_.DeviceID }) -join ', ') +
                   "). Refusing to choose - detach the others and re-run.")
        }
        Start-Sleep -Seconds 2
    }
    throw ("The eMMC did not appear as a USB disk within $TimeoutSeconds s, and no disk already " +
           "attached looks like one. Check the nRPIBOOT jumper and the USB cable.")
}

# The board serial is somewhere inside the PNPDeviceID of the exposed eMMC, and
# WHERE is not fixed. Measured on a CM4 through mass-storage-gadget64:
#
#   USBSTOR\DISK&VEN_MMCBLK0&PROD_&REV_\7&229AFA37&0&10000000A07C37A2&0
#
# The serial is the fourth &-field of the last path element, not the first. The
# earlier version took the last path element and then its first &-field, got
# "7", and reported that it could not identify the node - so the run fell back
# to default.env and would have written a card with the wrong hostname, the
# wrong timezone and none of the board's own settings. It said so in a warning
# and carried on, which is the failure this whole script exists to avoid.
# Bench-hit 2026-09-06 on glnode7, first real flash attempt.
#
# So: search the WHOLE id for a 16-hex token rather than trusting a position.
# If more than one matches, that is ambiguity and it stops instead of picking.
function Get-BoardSerialFromDisk {
    param($Disk)
    $id = [string] $Disk.PNPDeviceID
    # @(...) is not decoration. With ONE match the pipeline yields a plain
    # string, whose .Count is 1 and whose [0] is the first CHARACTER - so this
    # returned "1" instead of the serial and would have looked for a profile
    # named 1.env. Caught by testing the function against the real PNPDeviceID
    # rather than by reading it.
    $hits = @([regex]::Matches($id, '(?<![0-9a-fA-F])[0-9a-fA-F]{16}(?![0-9a-fA-F])') |
              ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -gt 1) {
        Write-Warn2 "the disk's PNPDeviceID contains $($hits.Count) 16-hex tokens ($($hits -join ', ')); refusing to guess which is the board serial."
        return $null
    }
    Write-Warn2 "no 16-hex board serial anywhere in the disk's PNPDeviceID ('$id'); cannot identify the node from it."
    return $null
}

# =============================================================================
# Installs
#
# Each one probes first, records the probe result in the manifest BEFORE it
# acts, and only then acts. The order matters: a manifest entry written after an
# install cannot distinguish "we put it there" from "it was already there", and
# that distinction is the whole basis of the cleanup.
# =============================================================================

function Install-Rpiboot {
    $pre = Test-Rpiboot
    Register-Install -Component 'rpiboot' -PreExisted $pre -Path $RPIBOOT_DIR `
        -Note 'usbboot installer; leaves no Add/Remove Programs entry, so it is probed by path.'
    if ($pre) { Write-Ok 'rpiboot already present - not installing, and cleanup will not remove it.'; return }
    if ($DryRun) { Write-Host "  (dry run) would download and run $RPIBOOT_URL"; return }
    Write-Step 'Installing rpiboot (usbboot).'
    $setup = Join-Path $env:TEMP 'rpiboot_setup.exe'
    Invoke-WebRequest -Uri $RPIBOOT_URL -OutFile $setup -UseBasicParsing
    Invoke-Shown $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -AllowFail | Out-Null
    Remove-Item -Force -ErrorAction SilentlyContinue $setup
    if (-not (Test-Rpiboot)) { throw 'rpiboot still not present after the installer ran.' }
    Write-Ok 'rpiboot installed.'
}

# The WinUSB driver that lets rpiboot talk to a board in bootloader mode.
#
# oem82.inf on this PC belongs to Raspberry Pi Imager, which ships and installs
# rpiboot-winusb.inf itself. It is NOT ours, and cleanup must never remove it -
# doing so would break Imager for every other job the operator uses it for. The
# manifest records that it pre-existed, which is what makes "never remove it"
# a fact on disk rather than a rule someone has to remember.
function Install-WinUsbDriver {
    $inf = Join-Path $IMAGER_DIR 'rpiboot-winusb.inf'
    $imagerOwns = Test-Path $inf
    Write-Host "  probe Imager's rpiboot-winusb.inf: $imagerOwns ($inf)"
    Register-Install -Component 'winusb-driver' -PreExisted $imagerOwns -Path $inf `
        -Note 'Raspberry Pi Imager ships and installs this driver (oem82.inf on this PC). Never removed by cleanup when preExisted.'
    if ($imagerOwns) {
        Write-Ok 'the WinUSB driver is provided by Raspberry Pi Imager - not installing, never removing.'
        return
    }
    Write-Warn2 'No driver found from Imager. rpiboot ships its own under usb_driver\; if the'
    Write-Warn2 'board is not detected, install it once from Device Manager and re-run.'
}

# =============================================================================
# Writing the card
#
# WHY rpi-imager AND NOT OUR OWN WRITER
#   Established by running it, not from documentation (2026-09-05). The CLI that
#   ships with Imager 2.0.11.1 parses and accepts:
#     --disable-verify  --enable-writing-system-drives  --sha256 <hash>
#     --cache-file  --first-run-script  --cloudinit-userdata
#     --cloudinit-networkconfig  --disable-eject  --debug  --quiet
#     --log-file <path>  --secure-boot-key  and the positionals <src> <dst>
#   and REJECTS invented ones (--apply-customization, --customization-file exit
#   1 while every option above exits 0 with --help). So it can write the image
#   and it can verify it against a known SHA-256 - which is far less code to own
#   than a writer of our own, and it is the same code path Raspberry Pi test.
#
#   What it CANNOT do is replay Imager's stored GUI customisation: there is no
#   flag for it, and the cloud-init flags it does have cannot deliver meta-data
#   (Imager generates its own instance-id and appends ds=nocloud;i=<uuid> to
#   cmdline.txt). We need meta-data, because instance-id is what makes a second
#   flash re-run first boot instead of silently skipping it. So the image is
#   written by rpi-imager and the seed is written by us, straight onto the FAT
#   partition afterwards.
#
#   rpi-imager.exe is a GUI-subsystem binary manifested requireAdministrator: it
#   prints nothing to an inherited stdout and it will not start unelevated.
#   --log-file is therefore how its output is read, and Assert-Elevated is why
#   it starts at all.
# =============================================================================

function Get-PinnedImage {
    if ($Image) {
        if (-not (Test-Path $Image)) { throw "-Image $Image does not exist." }
        Write-Ok "using $Image"
        return (Resolve-Path $Image).Path
    }
    if (-not (Test-Path $IMAGE_DIR)) { New-Item -ItemType Directory -Force -Path $IMAGE_DIR | Out-Null }
    $dst = Join-Path $IMAGE_DIR $IMAGE_NAME
    if (Test-Path $dst) {
        Write-Step "Verifying the cached image $dst"
        $h = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash.ToLower()
        if ($h -eq $IMAGE_XZ_SHA256) { Write-Ok "cached image sha256 $h - matches."; return $dst }
        Write-Warn2 "cached image sha256 $h does not match $IMAGE_XZ_SHA256 - re-downloading."
        Remove-Item -Force $dst
    }
    if ($DryRun) { Write-Host "  (dry run) would download $IMAGE_URL"; return $dst }
    Write-Step "Downloading $IMAGE_NAME (about 500 MB)."
    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $IMAGE_URL -OutFile $dst -UseBasicParsing }
    finally { $ProgressPreference = $old }
    $h = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash.ToLower()
    if ($h -ne $IMAGE_XZ_SHA256) { throw "Downloaded image sha256 $h does not match the pinned $IMAGE_XZ_SHA256." }
    Write-Ok "downloaded and verified (sha256 $h)."
    return $dst
}

function Write-CardImage {
    param([string] $ImagePath, $Disk)
    if (-not (Test-Imager)) {
        throw "Raspberry Pi Imager is not installed at $IMAGER_EXE. Install-Imager should have provided it; re-run -Action flash, which installs dependencies first."
    }
    $target = [string] $Disk.DeviceID    # \\.\PHYSICALDRIVEn

    # THE GUARD COMES BEFORE THE FLAG, and it is why the flag is acceptable.
    #
    # An eMMC exposed through mass-storage-gadget64 is NOT a removable volume as
    # far as Windows is concerned, so rpi-imager refuses it outright:
    #
    #     Destination drive is not in list of removable volumes.
    #     Or use --enable-writing-system-drives to overrule.
    #
    # That flag makes rpi-imager willing to write ANY disk, this PC's system SSD
    # included. Passing it on trust would mean one wrong $Disk away from
    # destroying the developer's machine. So the target is re-checked here,
    # against the properties only the gadget-exposed eMMC has, immediately
    # before the write - not at selection time, where an intervening
    # re-enumeration could have moved PHYSICALDRIVE numbers underneath us.
    $model = [string] $Disk.Model
    $pnp   = [string] $Disk.PNPDeviceID
    $sizeGB = [Math]::Round(([double] $Disk.Size) / 1GB, 1)
    if ($model -notmatch 'mmcblk' -or $pnp -notmatch '^USBSTOR\\') {
        throw ("REFUSING to write $target with --enable-writing-system-drives: it does not look like a " +
               "gadget-exposed eMMC (model='$model', PNPDeviceID='$pnp'). That flag lets rpi-imager write " +
               "any disk on this PC, so it is only ever passed for a target that passes this check.")
    }
    if ($sizeGB -gt 128) {
        throw "REFUSING to write $target ($sizeGB GB): far larger than any CM4 eMMC. Check which disk was selected."
    }
    Write-Ok "target re-checked immediately before writing: $target, model='$model', $sizeGB GB, USBSTOR."

    $log = Join-Path $STATE_DIR ('imager-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '.log')
    Write-Step "Writing $ImagePath to $target"
    Write-Host "       rpi-imager verifies against the published extract sha256 $IMAGE_RAW_SHA256"
    Write-Host "       its own log: $log"
    $imagerArgs = @('--cli', '--debug', '--disable-eject', '--enable-writing-system-drives',
                    '--sha256', $IMAGE_RAW_SHA256,
                    '--log-file', $log, $ImagePath, $target)
    if ($DryRun) {
        Write-Host "  (dry run) would run: `"$IMAGER_EXE`" $($imagerArgs -join ' ')"
        return
    }
    # Start-Process -Wait, NOT the call operator. rpi-imager.exe is a GUI-subsystem
    # binary: `& $exe` hands it to the shell and returns IMMEDIATELY, in about
    # 20 ms, while the process is still alive and writing. $LASTEXITCODE is then
    # not even stale - it is whatever the PREVIOUS command left behind, so a
    # successful-looking $code can be read from a write that has not started.
    #
    # What that cost, had it shipped: this function would announce "image written
    # and verified" over nothing, Find-BootPartition would then poll a card that
    # Imager is still writing and could match config.txt on a half-written FAT,
    # and Write-Seed would put the cloud-init files onto a partition being
    # overwritten underneath it. Every flash corrupt, and the script cheerful
    # about it. Found by the audit and reproduced on this PC with a GUI-subsystem
    # stand-in: the call operator returned in 22 ms with the process still
    # running and $LASTEXITCODE unchanged from the command before.
    # Quote EVERY argument. PowerShell 5.1's -ArgumentList takes an array and
    # joins it with spaces WITHOUT quoting, so a path containing a space is
    # silently split into two arguments and rpi-imager is handed nonsense. The
    # default paths under ProgramData\Scanbox have no spaces, which is exactly
    # what would make this survive testing and fail on somebody else's machine.
    $quoted = $imagerArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }
    $proc = Start-Process -FilePath $IMAGER_EXE -ArgumentList $quoted -Wait -PassThru -NoNewWindow
    $code = $proc.ExitCode
    if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
    else { Write-Warn2 "rpi-imager wrote no log at $log - its exit code ($code) is all we have." }
    if ($code -ne 0) { throw "rpi-imager exited $code. See $log." }

    # The exit code says the process ended, not that the card reads back right.
    #
    # rpi-imager re-reads what it wrote and hashes it. From a real log
    # (2026-09-06, the first successful flash of glnode7):
    #
    #     [DEBUG] Hash of uncompressed image: "e235fd24...c33a9"
    #     [DEBUG] Post-write verification using 6144 KB buffer for 2840 MB image
    #     [DEBUG] Verify hash: "e235fd24...c33a9"
    #     [DEBUG] Verify done in 86.87 seconds
    #
    # So the check is that `Verify hash` carries THE HASH WE PINNED - not that
    # the log lacks the word "error", and not a phase name like "Finalizing"
    # which an earlier version matched and reported as a verify. A card whose
    # read-back hashes to the expected image is the only positive statement
    # available here, and it is a real one.
    if (-not (Test-Path $log)) {
        # Not a warning to walk past: --sha256 was passed, so a run that wrote
        # no log wrote no verification result either, and the card is unproven.
        throw "rpi-imager exited 0 but wrote no log at $log, so nothing confirms it verified the card. Re-run, or check the card by hand before booting it."
    }
    $logText = (Get-Content $log -Raw)
    if ($logText -match ('(?i)Verify hash:\s*"?' + [regex]::Escape($IMAGE_RAW_SHA256))) {
        Write-Ok "card verified: rpi-imager read it back and hashed it to the pinned $IMAGE_RAW_SHA256."
    } elseif ($logText -match '(?i)Verify hash:\s*"?([0-9a-f]{64})') {
        throw ("THE CARD DOES NOT MATCH THE IMAGE. rpi-imager read it back as $($Matches[1]) " +
               "but the pinned image is $IMAGE_RAW_SHA256. Do not boot this card. See $log.")
    } else {
        throw ("rpi-imager exited 0 but its log records no verify at all (no 'Verify hash' line). " +
               "The card is unproven - re-run, or check it by hand before booting it. See $log.")
    }
}

# The boot partition is FAT32 and Windows mounts it on its own once the disk has
# been written and re-scanned. Which letter it gets is not predictable, so it is
# found by looking for the files the image is known to contain rather than by
# taking the first removable volume - the difference between addressing the card
# and addressing whatever else happens to be plugged in.
function Find-BootPartition {
    param($Disk, [int] $TimeoutSeconds = 120)
    Write-Host '  Looking for the FAT boot partition...'
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $halfway   = (Get-Date).AddSeconds([Math]::Floor($TimeoutSeconds / 2))
    $rescanned = $false
    while ((Get-Date) -lt $deadline) {
        foreach ($part in (Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='$($Disk.DeviceID)'} WHERE AssocClass=Win32_DiskDriveToDiskPartition")) {
            foreach ($vol in (Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($part.DeviceID)'} WHERE AssocClass=Win32_LogicalDiskToPartition")) {
                $root = $vol.DeviceID + '\'
                if ((Test-Path (Join-Path $root 'config.txt')) -and (Test-Path (Join-Path $root 'cmdline.txt'))) {
                    Write-Ok "boot partition at $root (config.txt and cmdline.txt present)"
                    return $root
                }
            }
        }
        # WINDOWS CACHES THE PARTITION TABLE OF A USB MASS-STORAGE DEVICE.
        #
        # rpi-imager has just replaced everything on the disk, but Windows goes
        # on believing the layout it read when the gadget first enumerated: the
        # drive reports Partitions=1 while no volume is ever surfaced for it, so
        # this loop can spin its whole timeout on a card that is written
        # perfectly. Measured on glnode7, 2026-09-06, twice - the operator's
        # workaround the first time was to power-cycle the board, which
        # re-enumerates the gadget and forces the re-read.
        #
        # `diskpart rescan` does the same thing without touching the hardware.
        # It needs elevation, which this script already has. Done once, halfway
        # through the wait, so a card that was simply slow to settle is given
        # its chance first.
        # WINDOWS DOES NOT AUTO-MOUNT THIS PARTITION, and the loop above can
        # only see volumes that have a drive letter.
        #
        # The card is written correctly - Get-Partition shows an MBR disk with a
        # 512 MB FAT32 partition and a 2.4 GB rootfs - but the gadget-exposed
        # eMMC is not flagged removable (the same property that made rpi-imager
        # refuse it), so Windows assigns no letter and Win32_LogicalDisk lists
        # nothing. The loop then spins its whole timeout on a perfectly good
        # card. Measured on glnode7, 2026-09-06, on the first flash that got
        # this far.
        #
        # So: give it a letter. A rescan first, in case the table itself is
        # stale, then assign to the FAT partition of THIS disk only - never to
        # whatever else happens to be unlettered.
        if (-not $rescanned -and (Get-Date) -gt $halfway) {
            Write-Host '  no lettered volume yet - re-reading the partition table and mounting the FAT partition...'
            try {
                'rescan' | & "$env:SystemRoot\System32\diskpart.exe" | Out-Null
                Write-Ok 'rescan issued.'
            } catch {
                Write-Warn2 "diskpart rescan failed: $($_.Exception.Message)"
            }
            try {
                $dnum = ([string]$Disk.DeviceID) -replace '.*PHYSICALDRIVE', ''
                $fat  = Get-Partition -DiskNumber ([int]$dnum) -ErrorAction Stop |
                        Where-Object { -not $_.DriveLetter -and $_.Size -lt 2GB }
                foreach ($p in @($fat)) {
                    Add-PartitionAccessPath -DiskNumber ([int]$dnum) -PartitionNumber $p.PartitionNumber `
                        -AssignDriveLetter -ErrorAction Stop
                    Write-Ok "assigned a drive letter to partition $($p.PartitionNumber) ($([Math]::Round($p.Size/1MB)) MB)."
                }
                if (-not $fat) { Write-Host '  every partition on this disk already has a letter.' }
            } catch {
                Write-Warn2 "could not assign a drive letter: $($_.Exception.Message)"
            }
            $rescanned = $true
        }
        Start-Sleep -Seconds 3
    }
    throw ("Could not find the boot partition on $($Disk.DeviceID) within $TimeoutSeconds s, even after a " +
           "diskpart rescan. Windows is still holding the old partition table. Power-cycle the board with " +
           "the nRPIBOOT jumper still fitted so the gadget re-enumerates, then re-run. If Windows offered " +
           "to format a drive, decline it.")
}

# =============================================================================
# Cleanup
#
# Removes ONLY what the manifest says this script installed, and proves the
# result by re-running each probe afterwards. An uninstaller's exit code is not
# evidence: it reports that it ran, not that the thing is gone.
# =============================================================================

function Invoke-Cleanup {
    Write-Step 'Cleanup - undoing only what bootstrap_win.ps1 installed.'
    $m = Read-Manifest
    if (-not $m.entries -or @($m.entries).Count -eq 0) {
        Write-Ok "manifest $MANIFEST_PATH records no installs - there is nothing of ours to remove."
    }
    foreach ($e in @($m.entries)) {
        if ($e.preExisted) {
            Write-Ok "$($e.component): pre-existed this script - LEFT ALONE. $($e.note)"
            continue
        }
        switch ($e.component) {
            'rpiboot' {
                $unins = Join-Path $RPIBOOT_DIR 'Uninstall.exe'
                if (Test-Path $unins) {
                    if ($DryRun) { Write-Host "  (dry run) would run $unins /VERYSILENT" }
                    else { Invoke-Shown $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -AllowFail | Out-Null }
                } else {
                    Write-Warn2 "no uninstaller at $unins - remove $RPIBOOT_DIR by hand."
                }
            }
            'winusb-driver' {
                Write-Warn2 "$($e.component): this script never installs a driver, so there is nothing to undo."
            }
            'age' {
                # A file in this script's own directory: removing it takes
                # nothing else with it and touches no PATH.
                if ($DryRun) { Write-Host "  (dry run) would delete $AGE_EXE" }
                elseif (Test-Path $AGE_EXE) { Remove-Item -Force $AGE_EXE; Write-Ok "deleted $AGE_EXE" }
                else { Write-Ok 'age was already gone.' }
            }
            'git' {
                $unins = 'C:\Program Files\Git\unins000.exe'
                if (Test-Path $unins) {
                    if ($DryRun) { Write-Host "  (dry run) would run $unins /VERYSILENT" }
                    else { Invoke-Shown $unins @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -AllowFail | Out-Null }
                } else {
                    Write-Warn2 "no uninstaller at $unins - remove Git for Windows from Settings by hand."
                }
            }
            'imager' {
                # Imager also owns the WinUSB driver rpiboot needs. Removing it
                # takes that with it, which is correct when this script put it
                # there and nobody else was using it - and it is why the driver
                # entry is recorded separately as pre-existing whenever Imager was.
                $unins = Join-Path $IMAGER_DIR 'Uninstall.exe'
                if (Test-Path $unins) {
                    if ($DryRun) { Write-Host "  (dry run) would run $unins /quiet" }
                    else { Invoke-Shown $unins @('/quiet', '/norestart') -AllowFail | Out-Null }
                } else {
                    Write-Warn2 "no uninstaller at $unins - remove Raspberry Pi Imager from Settings by hand."
                }
            }
            default {
                Write-Warn2 "$($e.component): no removal step is defined for this component."
            }
        }
    }
    Write-Host ''
    Write-Step 'Verifying the cleanup by re-running every probe (not by exit codes).'
    $rpi = Test-Rpiboot
    $img = Test-Imager
    $entryRpi = Get-ManifestEntry 'rpiboot'
    if ($entryRpi -and -not $entryRpi.preExisted -and $rpi) {
        Write-Bad 'rpiboot is STILL present although this script installed it - remove it by hand.'
    } elseif ($entryRpi -and -not $entryRpi.preExisted) {
        Write-Ok 'rpiboot is gone (probed, not assumed).'
    }
    Write-Host ''
    $entryImg = Get-ManifestEntry 'imager'
    if ($entryImg -and -not $entryImg.preExisted -and $img) {
        Write-Bad 'Raspberry Pi Imager is STILL present although this script installed it - remove it by hand.'
    } elseif ($entryImg -and -not $entryImg.preExisted) {
        Write-Ok 'Raspberry Pi Imager is gone (probed, not assumed).'
    } else {
        Write-Ok "Raspberry Pi Imager present: $img - it pre-existed this script, so it was left alone."
    }
    $entryAge = Get-ManifestEntry 'age'
    if ($entryAge -and -not $entryAge.preExisted) {
        if (Test-Path $AGE_EXE) { Write-Bad "age is STILL at $AGE_EXE - remove it by hand." }
        else { Write-Ok 'age is gone (probed, not assumed).' }
    }
    $entryGit = Get-ManifestEntry 'git'
    if ($entryGit -and -not $entryGit.preExisted) {
        if (Get-GitPath) { Write-Bad 'Git is STILL present although this script installed it - remove it by hand.' }
        else { Write-Ok 'Git is gone (probed, not assumed).' }
    }
    Write-Host ''
    Write-Host 'Cached files this script created are left in place; they are data, not installs:'
    foreach ($p in @($IMAGE_DIR, $CLONE_DIR, $HASH_PATH, $KEYS_PATH)) {
        $exists = Test-Path $p
        Write-Host ("  {0,-5} {1}" -f $exists, $p)
    }
    Write-Host "Delete $STATE_DIR yourself if you want them gone."
}

# =============================================================================
# Actions
# =============================================================================

function Invoke-Probe {
    Write-Step 'Probing this PC.'
    Write-Host "  elevated                   : $(Test-Elevated)"
    [void] (Test-Rpiboot)
    [void] (Test-Imager)
    $ssl = Get-OpenSslPath; Write-Host "  probe openssl.exe          : $([bool]$ssl) ($ssl)"
    $age = Get-AgePath;     Write-Host "  probe age.exe              : $([bool]$age) ($age)"
    $git = Get-GitPath;     Write-Host "  probe git.exe              : $([bool]$git) ($git)"
    Write-Host ''
    Write-Step 'Raspberry Pi Imager customisation values this script reuses.'
    foreach ($n in @('sshUserName', 'keyboard', 'sshPasswordAuth', 'timezone')) {
        Write-Host ("  {0,-16} = {1}" -f $n, (Get-ImagerRegValue $n))
    }
    $pw = Get-ImagerRegValue 'sshUserPassword'
    if ($pw) { Write-Host ("  {0,-16} = {1}... ({2} chars, a crypt hash - never a plaintext)" -f 'sshUserPassword', $pw.Substring(0, [Math]::Min(7, $pw.Length)), $pw.Length) }
    else     { Write-Host ("  {0,-16} = (absent)" -f 'sshUserPassword') }
    $k = Get-ImagerRegValue 'sshAuthorizedKeys'
    if ($k) { Write-Host ("  {0,-16} = {1} key(s)" -f 'sshAuthorizedKeys', @($k -split "`r?`n" | Where-Object { $_.Trim() }).Count) }
    Write-Host ''
    Write-Host '  NOTE: timezone above is Imager''s and is deliberately NOT used. The node'
    Write-Host '        profile supplies it, because it is a fact about the board, not the PC.'
    Write-Host ''
    $root = Find-LocalCheckout
    if ($root) { [void] (Test-KernelAllowlist -Root $root) }
    else { Write-Warn2 'no local checkout - run the kernel reconciliation from one, or use flash, which fetches it.' }
    Write-Host ''
    Write-Step "Install manifest ($MANIFEST_PATH)"
    $m = Read-Manifest
    if (@($m.entries).Count -eq 0) { Write-Host '  (empty - this script has installed nothing on this PC)' }
    else { foreach ($e in @($m.entries)) { Write-Host ("  {0,-14} preExisted={1,-5} by={2} {3}" -f $e.component, $e.preExisted, $e.installedBy, $e.path) } }
}

function Invoke-Render {
    $root = Resolve-RepoRoot
    [void] (Test-KernelAllowlist -Root $root)
    $dest = $OutDir
    if (-not $dest) { $dest = Join-Path (Get-Location) 'seed' }
    $ctx = New-SeedContext -Root $root -BoardSerial $Serial
    Write-Step "Rendering the seed into $dest"
    [void] (Write-Seed -Root $root -Ctx $ctx -Destination $dest -Token '')
    Write-Host ''
    Write-Ok 'Rendered with no passphrase file. This is the seed only - nothing was flashed.'
}

function Invoke-Flash {
    Assert-Elevated -ResumeAction 'flash'
    Write-Step 'Full flash: bare eMMC to a node that deploys itself.'
    Write-Host ''
    Write-Host 'You will be asked for exactly one thing (the deploy passphrase) and asked to'
    Write-Host 'move the jumper twice. Everything else is automatic.'
    Write-Host ''

    # Before Resolve-RepoRoot: on a PC with no checkout that call needs git and
    # age, which are two of the three installed here.
    Install-Dependencies

    $root = Resolve-RepoRoot
    if (-not (Test-KernelAllowlist -Root $root)) {
        throw 'The pinned image ships a kernel that is not on the allowlist. Stopping. Do not widen the allowlist to get past this.'
    }

    Install-Rpiboot
    Install-WinUsbDriver
    $imagePath = Get-PinnedImage

    $known = @(Get-WmiObject Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' } | ForEach-Object { $_.DeviceID })
    Write-Host "  USB disks already attached: $($known.Count)"

    $already = Get-GadgetEmmc
    if ($already) {
        Write-Ok ("the board is already in mass-storage mode ({0}) - not waiting for the bootloader, not running rpiboot." -f $already.DeviceID)
    } else {
        [void] (Wait-ForBootloader)
        Write-Step 'Loading the mass-storage gadget (32.8 MB/s, against about 5 MB/s for the stock one).'
        Invoke-Rpiboot
    }

    $disk = Wait-ForMassStorage -KnownDiskIds $known

    $boardSerial = $Serial
    if (-not $boardSerial) {
        $boardSerial = Get-BoardSerialFromDisk -Disk $disk
        if ($boardSerial) { Write-Ok "board serial read from the device: $boardSerial" }
        else { Write-Warn2 'the board serial could not be read from the device.' }
    }
    if ($boardSerial) {
        $prof = Join-Path $root ('host\profiles\' + $boardSerial + '.env')
        if (-not (Test-Path $prof)) {
            Write-Bad "no host/profiles/$boardSerial.env in this checkout."
            Write-Host '       Refusing to hand this board another node profile. Either add its'
            Write-Host '       profile and re-run, or re-run with -Serial to say which one to use.'
            throw "No profile for board serial $boardSerial."
        }
    }

    $ctx = New-SeedContext -Root $root -BoardSerial $boardSerial

    $pass = ''
    if (-not $NoPassphrase) { $pass = Get-DeployToken }
    else { Write-Warn2 '-NoPassphrase: the node will come up provisioned but will NOT deploy itself.' }

    Write-CardImage -ImagePath $imagePath -Disk $disk
    $bootRoot = Find-BootPartition -Disk $disk
    Write-Step "Writing the cloud-init seed to $bootRoot"
    [void] (Write-Seed -Root $root -Ctx $ctx -Destination $bootRoot -Token $pass)
    $pass = $null
    [GC]::Collect()

    # Read the seed back off the card. The write can report success and leave
    # nothing behind on a failing or counterfeit device - rpi-imager has its own
    # message for exactly that - so presence is confirmed from the filesystem.
    Write-Step 'Reading the seed back off the card.'
    foreach ($f in @('user-data', 'meta-data', 'network-config', 'scanbox-provision.sh')) {
        $p = Join-Path $bootRoot $f
        if (Test-Path $p) { Write-Ok ("{0}: {1} bytes on the card" -f $f, (Get-Item $p).Length) }
        else { Write-Bad "$f is NOT on the card."; throw "Seed file $f did not survive the write." }
    }
    if (-not $NoPassphrase) {
        $p = Join-Path $bootRoot 'scanbox-deploy.token'
        if (Test-Path $p) { Write-Ok 'scanbox-deploy.token is on the card (the node moves it to tmpfs and shreds this copy in the first seconds of first boot).' }
        else { Write-Bad 'scanbox-deploy.token is NOT on the card - the node will come up but will not deploy.' }
    }

    Write-Host ''
    Write-Step 'Done. Two things left, and both are physical:'
    Write-Host '   1. Power the board OFF and REMOVE the nRPIBOOT jumper.' -ForegroundColor Yellow
    Write-Host '   2. Power it on with the network cable in.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "   It will boot, take its identity from the seed, fetch bootstrap_node.sh, deploy"
    Write-Host "   itself and reboot once. Expect roughly 30-60 minutes for a first provision."
    Write-Host "   Its record is /var/log/scanbox-provision.log and then ~/scanbox/deploy.log."
    Write-Host "   Verify with:  ssh $($ctx.Map.SSH_USER)@$($ctx.Map.HOSTNAME) '~/scanbox/host/boot_selftest.sh'"
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '  SCANBOX bootstrap_win.ps1' -ForegroundColor Cyan
        Write-Host '  ================='
        Write-Host '   1) Flash a board          - the whole path, bare eMMC to a deployed node'
        Write-Host '   2) Render a seed only     - no board, no writing; produces the four files'
        Write-Host '   3) Probe this PC          - tools, Imager values, kernel allowlist, manifest'
        Write-Host '   4) Clean up               - remove only what this script installed'
        Write-Host '   0) Quit'
        Write-Host ''
        $choice = Read-Host '  choice'
        switch ($choice) {
            '1' { Invoke-Flash;   return }
            '2' { Invoke-Render;  return }
            '3' { Invoke-Probe }
            '4' { Invoke-Cleanup; return }
            '0' { return }
            default { Write-Warn2 "not a choice: '$choice'" }
        }
    }
}

# =============================================================================
# Main
# =============================================================================

if (-not (Test-Path $STATE_DIR)) { New-Item -ItemType Directory -Force -Path $STATE_DIR | Out-Null }
if ($DryRun) { Write-Warn2 'DRY RUN - nothing will be installed, downloaded or written.' }

# EVERY RUN LEAVES A TRANSCRIPT, and an elevated one WAITS before it closes.
#
# An elevated relaunch owns its own console window: when the script ends - or
# throws - that window closes and takes the only copy of the output with it.
# Reported from the field on 2026-09-07: "ha impreso alguna cosa y ha cerrado la
# ventana", with nothing left to read afterwards. The imager log is no help,
# because a failure before the write never reaches rpi-imager at all.
#
# So: a transcript per run under $STATE_DIR, started before anything can fail
# and stopped in `finally`; the error printed in full rather than as one line;
# and, in the window this script opened itself, a keypress before it closes.
# Best-effort by design - a machine that refuses transcription still runs.
$LOG_PATH = Join-Path $STATE_DIR ('bootstrap_win-' +
    (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') +
    $(if ($Relaunched) { '-elevated' } else { '' }) + '.log')
$transcribing = $false
try { Start-Transcript -Path $LOG_PATH -ErrorAction Stop | Out-Null; $transcribing = $true }
catch { Write-Warn2 "could not start a transcript ($($_.Exception.Message)); continuing without one." }
if ($transcribing) { Write-Host "  transcript: $LOG_PATH" }

$failed = $false
try {
    switch ($Action) {
        'flash'   { Invoke-Flash }
        'render'  { Invoke-Render }
        'probe'   { Invoke-Probe }
        'cleanup' { Invoke-Cleanup }
        'menu'    { Show-Menu }
    }
}
catch {
    $failed = $true
    Write-Host ''
    Write-Bad $_.Exception.Message
    if ($_.InvocationInfo) { Write-Host "  at $($_.InvocationInfo.PositionMessage)" }
    Write-Host ''
    Write-Host ($_.ScriptStackTrace)
}
finally {
    if ($transcribing) {
        Write-Host ''
        Write-Host "  transcript: $LOG_PATH"
        try { Stop-Transcript | Out-Null } catch { }
    }
    if ($Relaunched) {
        Write-Host ''
        Write-Host '  This window was opened by the script and will close when you press a key.' -ForegroundColor Cyan
        if ($Host.UI.RawUI) { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
        else { Read-Host '  press Enter to close' | Out-Null }
    }
}
if ($failed) { exit 1 }
