# One-command, from-scratch build of the Qwen3.8-Flash-Next NVFP4 recipe on Windows 11 ARM64.
#
# WHAT THIS SCRIPT PRODUCES
#   The repository provides scripts, patches and docs. This script recreates everything the
#   engine needs on this machine: the TensorFold checkout, the non-GPL runtime DLLs, the
#   locally built FFmpeg stack, and finally tensorfold\dist\native with the engine binary.
#
# WHAT IT DOES (stages run in dependency order; each stage is idempotent)
#   1. preflight  - detect Zig 0.17, VS2022 BuildTools ARM64, CUDA 13.4, git/python/curl/tar.
#                   -PreflightOnly / -NoAutoSetup: detect only; full build self-heals Zig + VSBT.
#   2. source     - fetch TensorFold v1.2.7 at the pinned commit into .\tensorfold (if absent).
#   3. patches    - apply patches\windows\*.patch (LF-normalized) via scripts\apply-patches.ps1.
#   4. runtime    - download the non-GPL runtime DLLs (turbojpeg / webp / pdfium / tfgrammar)
#                   from pinned upstream releases and extract them into third_party\optional-libs.
#   5. video      - assemble the FFmpeg video stack natively via scripts\build-gpl-video.ps1:
#                   pinned wheel DLLs + source tarball headers + zig dlltool import libs + tfvideo.dll.
#   6. engine     - zig build native install -> tensorfold\dist\native\bin\tensorfold-native.exe,
#                   then install all runtime DLLs into dist\native\lib (scripts\build.ps1).
#   7. verify     - check ARM64 PE headers, runtime DLL presence and capabilities --json.
#
# PREREQUISITES / SELF-SETUP (fully native Windows ARM64 - no MSYS2, no conda, no cross toolchain)
#   - Zig 0.17.0 (aarch64-windows) ............ auto-downloaded when missing
#   - Visual Studio 2022 Build Tools ARM64 .... auto-installed silently when elevated
#   - CUDA Toolkit 13.4 (nvcc.exe) ............ OPERATOR MUST INSTALL; script only prompts
#   - git, python, curl, tar on PATH .......... must be present
#   -PreflightOnly / -NoAutoSetup never download or install anything.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .\build.ps1                      # all stages
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -PreflightOnly       # only detect tools
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipVideo           # DIAGNOSTIC ONLY: engine + runtime, no video
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Stage source        # a single stage
#   powershell -ExecutionPolicy Bypass -File .\build.ps1 -Stage runtime -ForceRuntime
#   See build_skill.md for the AI-assistant build guide and troubleshooting.

[CmdletBinding()]
param(
  [string]$ProjectRoot = '',
  [string]$ZigExe = 'D:\building\zig-aarch64-windows-0.17.0\zig.exe',
  [string]$Nvcc = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin\nvcc.exe',
  [string]$VsBuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
  [int]$Jobs = 0,
  [ValidateSet('all', 'preflight', 'source', 'patches', 'runtime', 'video', 'engine', 'verify')]
  [string]$Stage = 'all',
  [switch]$PreflightOnly,
  [switch]$NoAutoSetup,
  [switch]$SkipVideo,
  [switch]$SkipRuntime,
  [switch]$ForceRuntime,
  [switch]$SkipPatches,
  [switch]$NoClean
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = $PSScriptRoot }
$Tensorfold = Join-Path $ProjectRoot 'tensorfold'
$Dist = Join-Path $Tensorfold 'dist'
$OptionalLibs = Join-Path $ProjectRoot 'third_party\optional-libs'
$EngineExe = Join-Path $Dist 'native\bin\tensorfold-native.exe'
$TfRepo = 'https://github.com/ashhart/TensorFold.git'
$TfRef = '93a2e93ecebff8aa52b88e58c5dd222516e69c5f'   # v1.2.7, pinned in scripts/config.sh
if ($Jobs -le 0) { $Jobs = [int]${env:NUMBER_OF_PROCESSORS}; if ($Jobs -le 0) { $Jobs = 20 } }

function Say { param([string]$m) Write-Host "[build] $m" }
function Ok   { param([string]$m) Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Miss { param([string]$m) Write-Host "  [MISS] $m" -ForegroundColor Red }
function Want { param([string]$s) ($Stage -eq 'all' -or $Stage -eq $s) }

# ---------------------------------------------------------------- 1. PREFLIGHT / TOOLCHAIN SETUP
# Detection and, when allowed, self-healing of the three required toolchains:
#   - Zig 0.17.0 (aarch64-windows) ....... downloaded + extracted automatically when missing
#   - VS2022 Build Tools native ARM64 .... installed silently via the official bootstrapper when missing
#   - CUDA Toolkit 13.4 (nvcc) ........... NEVER installed; operator is prompted to install it
# -PreflightOnly  : detect and report only, perform NO download/install (safe diagnostic mode).
# -NoAutoSetup    : detect and fail with instructions, perform NO download/install.
# The operator (not this script's author) is the one who runs it; installs only happen when the
# operator runs the full script without those switches.
function Invoke-Preflight {
  Say "PREFLIGHT - detecting Zig 0.17.0 / VS2022 ARM64 / CUDA 13.4"
  $auto = (-not $PreflightOnly) -and (-not $NoAutoSetup)
  $fail = $false

  # ---- (a) Zig 0.17.0 -------------------------------------------------------------
  $zigUrl = 'https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip'
  if (Test-Path -LiteralPath $ZigExe) {
    $zv = (& $ZigExe version 2>&1).Trim()
    Ok "Zig 0.17: $ZigExe (version $zv)"
    if ($zv -ne '0.17.0') { Say "WARNING: expected 0.17.0, found $zv" }
  } else {
    Miss "Zig not found: $ZigExe"
    if ($auto) {
      $zigRoot = Split-Path -Parent $ZigExe
      $zigZip = Join-Path $env:TEMP 'zig-aarch64-windows-0.17.0.zip'
      Say "downloading Zig 0.17.0 -> $zigZip"
      & curl -sSfL -o $zigZip $zigUrl
      if ($LASTEXITCODE -ne 0) { throw "Zig download failed: $zigUrl" }
      $zipHash = (Get-FileHash -LiteralPath $zigZip -Algorithm SHA256).Hash.ToLowerInvariant()
      Ok "Zig archive sha256=$zipHash"
      Say "extracting Zig into $zigRoot (zip root is zig-aarch64-windows-0.17.0)"
      $extractTo = Join-Path $env:TEMP 'zig-extract-0.17.0'
      if (Test-Path -LiteralPath $extractTo) { Remove-Item -LiteralPath $extractTo -Recurse -Force }
      Expand-Archive -LiteralPath $zigZip -DestinationPath $extractTo -Force
      $unpacked = Join-Path $extractTo 'zig-aarch64-windows-0.17.0'
      if (-not (Test-Path -LiteralPath $unpacked)) { throw "unexpected Zig archive layout under $extractTo" }
      New-Item -ItemType Directory -Force -Path $zigRoot | Out-Null
      Copy-Item -LiteralPath (Join-Path $unpacked '*') -Destination $zigRoot -Recurse -Force
      if (Test-Path -LiteralPath $ZigExe) { Ok "Zig installed: $ZigExe" }
      else { Miss "Zig extract completed but $ZigExe still missing"; $fail = $true }
    } else {
      Say "To install Zig manually: download $zigUrl and extract so zig.exe is at $ZigExe"
      $fail = $true
    }
  }

  # ---- (b) VS2022 Build Tools native ARM64 ---------------------------------------
  $devShell = Join-Path $VsBuildTools 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
  # MSVC target compilers live under bin\<Host>\arm64\ (Hostx64 / Hostarm64), not bin\arm64\.
  $armCl = Get-ChildItem -LiteralPath (Join-Path $VsBuildTools 'VC\Tools\MSVC') -ErrorAction SilentlyContinue |
             ForEach-Object { @((Join-Path $_.FullName 'bin\Hostx64\arm64\cl.exe'),
                                (Join-Path $_.FullName 'bin\Hostarm64\arm64\cl.exe')) } |
             Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ((Test-Path -LiteralPath $devShell) -and $armCl) {
    Ok "VS2022 BuildTools native ARM64: $armCl"
  } else {
    Miss "VS2022 Build Tools native ARM64 tools missing under $VsBuildTools"
    $btExe = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
    $btArgs = @('--quiet', '--wait', '--norestart',
                '--add', 'Microsoft.VisualStudio.Workload.VCTools',
                '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64')
    Say "Command to install (requires an elevated prompt):"
    Say "  vs_buildtools.exe $($btArgs -join ' ')"
    if ($auto) {
      $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                 ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
      if (-not $isAdmin) {
        Say "NOT ELEVATED: cannot install VS Build Tools silently without admin rights."
        Say "Re-run PowerShell as Administrator, or run the command above manually."
        $fail = $true
      } else {
        $btLocal = Join-Path $env:TEMP 'vs_buildtools.exe'
        Say "downloading VS Build Tools bootstrapper -> $btLocal"
        & curl -sSfL -o $btLocal $btExe
        if ($LASTEXITCODE -ne 0) { throw "VS Build Tools bootstrapper download failed: $btExe" }
        Say "installing VS2022 ARM64 build tools (silent; this can take several minutes)"
        $p = Start-Process -FilePath $btLocal -ArgumentList $btArgs -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
          Miss "VS Build Tools installer exited $($p.ExitCode) (3010 = reboot required, acceptable)"; $fail = $true
        } else {
          Ok "VS Build Tools installer exit $($p.ExitCode); reopen this shell so PATH/DevShell refresh"
          $fail = $true   # even on success, require a fresh shell before continuing
          Say "Restart PowerShell and re-run build.ps1 to pick up the new toolchain."
        }
      }
    } else {
      $fail = $true
    }
  }

  # ---- (c) CUDA Toolkit 13.4 (prompt only, never install) -------------------------
  if (Test-Path -LiteralPath $Nvcc) {
    Ok "CUDA 13.4 nvcc: $Nvcc"
  } else {
    Miss "CUDA Toolkit 13.4 nvcc not found: $Nvcc"
    Say "CUDA is NOT installed automatically. Install the native ARM64 GA build from:"
    Say "  https://developer.nvidia.com/cuda-13-4-3-download-archive?target_os=Windows&target_arch=arm64&target_version=11&target_type=exe_local"
    Say "Installer: cuda_13.4.3_windows_arm64.exe (GA, ~3.5 GB; reboot, then re-run build.ps1)."
    $fail = $true
  }

  # ---- generic PATH tools ---------------------------------------------------------
  foreach ($t in @('git', 'python', 'curl', 'tar')) {
    if (Get-Command $t -ErrorAction SilentlyContinue) { Ok "$t on PATH" }
    else { Miss "$t not on PATH"; $fail = $true }
  }

  if ($PreflightOnly) {
    Say "PreflightOnly: detection complete (no download/install performed)."
    return
  }
  if ($fail) { throw "Preflight failed. See build_skill.md for details. CUDA and VS admin rights require operator action." }
  Ok "Preflight passed"
}

# ---------------------------------------------------------------- 2. SOURCE
function Invoke-Source {
  if (Test-Path -LiteralPath (Join-Path $Tensorfold 'build.zig')) {
    Say "TensorFold source already present at $Tensorfold"
  } else {
    Say "fetching TensorFold $TfRef into $Tensorfold"
    New-Item -ItemType Directory -Force -Path $Tensorfold | Out-Null
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    & $git -C $Tensorfold init -q
    & $git -C $Tensorfold remote remove origin 2>$null
    & $git -C $Tensorfold remote add origin $TfRepo
    & $git -C $Tensorfold fetch -q --depth 1 origin $TfRef
    if ($LASTEXITCODE -ne 0) { throw "failed to fetch TensorFold $TfRef" }
    & $git -C $Tensorfold checkout -q --detach FETCH_HEAD
    & $git -C $Tensorfold config core.autocrlf false
  }
  $head = (& git -C $Tensorfold rev-parse HEAD).Trim()
  if ($head -ne $TfRef) { Say "WARNING: checkout is $head, recipe patches target $TfRef" }
  Ok "TensorFold $head"
}

# ---------------------------------------------------------------- 3. PATCHES
function Invoke-Patches {
  if ($SkipPatches) { Say 'patches skipped (-SkipPatches)'; return }
  & (Join-Path $PSScriptRoot 'scripts\apply-patches.ps1') -Tensorfold $Tensorfold
  if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'apply-patches.ps1 failed' }
  Ok 'Windows patches applied'
}

# ---------------------------------------------------------------- 4. RUNTIME (non-GPL DLLs)
# Download each pinned archive, extract the one DLL we need by globbing inside it, and write it
# to third_party\optional-libs under the name the engine expects. Extraction happens in a temp
# dir via python stdlib (zipfile/tarfile) or Windows tar.exe - no package install.
function Invoke-Runtime {
  Say "RUNTIME - fetching non-GPL runtime DLLs into $OptionalLibs"
  New-Item -ItemType Directory -Force -Path $OptionalLibs | Out-Null
  $tmp = Join-Path $ProjectRoot '.work\runtime-dl'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $python = (Get-Command python.exe -ErrorAction Stop).Source
  $extractPy = Join-Path $tmp 'extract.py'
  # PY: archive path, dest path, case-insensitive glob of the member to find
  @'
import sys, os, glob, shutil, zipfile, tarfile, tempfile
arc, dest, pattern = sys.argv[1], sys.argv[2], sys.argv[3]
work = tempfile.mkdtemp(prefix="tf-extract-")
try:
    if zipfile.is_zipfile(arc):
        with zipfile.ZipFile(arc) as z: z.extractall(work)
    elif tarfile.is_tarfile(arc):
        with tarfile.open(arc) as t:
            try: t.extractall(work, filter="data")
            except TypeError: t.extractall(work)
    else:
        print("UNSUPPORTED_ARCHIVE", arc); sys.exit(2)
    hits = [p for p in glob.glob(os.path.join(work, "**", pattern), recursive=True)
            if os.path.basename(p).lower().endswith(".dll")]
    if not hits:
        print("MEMBER_NOT_FOUND", pattern); sys.exit(3)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy2(hits[0], dest)
    print("EXTRACTED", os.path.basename(hits[0]), "->", dest)
finally:
    shutil.rmtree(work, ignore_errors=True)
'@ | Set-Content -LiteralPath $extractPy -Encoding ascii

  # Name = target DLL; Url = pinned upstream; Pattern = glob inside the archive.
  $items = @(
    @{ Name='turbojpeg.dll'; Pattern='turbojpeg*.dll';
       Url='https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.1/libjpeg-turbo-3.1.1-vc-arm64.exe' },
    @{ Name='pdfium.dll'; Pattern='pdfium.dll';
       Url='https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/7725/pdfium-win-arm64.tgz' },
    @{ Name='tfgrammar.dll'; Pattern='*.dll';
       Url='https://files.pythonhosted.org/packages/52/55/b78d9b56b7af04c8af8ab58e6d18c5977fd577b649b5caf698337af95b75/xgrammar-0.2.8-cp312-cp312-win_arm64.whl' },
    @{ Name='libwebpdecoder.dll'; Pattern='libwebpdecoder*.dll';
       Url='https://files.pythonhosted.org/packages/a5/78/16864f1aa2c3ac5017f15132b85c6d3c74bb85caca8c45ce836ad30dfe20/av-19.0.1-cp312-abi3-win_arm64.whl' }
  )

  foreach ($it in $items) {
    $dest = Join-Path $OptionalLibs $it.Name
    if ((Test-Path -LiteralPath $dest) -and (-not $ForceRuntime)) { Ok "$($it.Name) already present"; continue }
    $archive = Join-Path $tmp ([System.IO.Path]::GetFileName($it.Url))
    if (-not (Test-Path -LiteralPath $archive)) {
      Say "downloading $($it.Name) from $($it.Url)"
      & curl -sSfL -o $archive $it.Url
      if ($LASTEXITCODE -ne 0) { throw "download failed: $($it.Url)" }
    }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Say "archive sha256=$hash  $($it.Name)"
    & $python $extractPy $archive $dest $it.Pattern
    if ($LASTEXITCODE -ne 0) { throw "extract failed for $($it.Name) (see error above)" }
    Ok "$($it.Name) -> $dest"
  }

  # libsharpyuv must also sit next to the executable; PyAV ships it beside libwebpdecoder.
  $sharpyuv = Join-Path $OptionalLibs 'libsharpyuv.dll'
  if (-not (Test-Path -LiteralPath $sharpyuv)) {
    $avWheel = Join-Path $tmp 'av-19.0.1-cp312-abi3-win_arm64.whl'
    if (Test-Path -LiteralPath $avWheel) {
      & $python $extractPy $avWheel $sharpyuv 'libsharpyuv*.dll'
      if ($LASTEXITCODE -eq 0) { Ok "libsharpyuv.dll extracted" }
    }
  }
  Ok "runtime DLL inventory:"
  Get-ChildItem -LiteralPath $OptionalLibs -Filter '*.dll' | ForEach-Object {
    Write-Host ("    {0,-24} {1,10} bytes" -f $_.Name, $_.Length)
  }
}

# ---------------------------------------------------------------- 5. VIDEO (native)
function Invoke-Video {
  if ($SkipVideo) { Say 'video stage skipped (-SkipVideo)'; return }
  $vargs = @('-ProjectRoot', $ProjectRoot, '-ZigExe', $ZigExe, '-Jobs', "$Jobs")
  & (Join-Path $PSScriptRoot 'scripts\build-gpl-video.ps1') @vargs
  Ok 'FFmpeg video stack assembled natively (wheel DLLs + source headers + zig dlltool import libs)'
}

# ---------------------------------------------------------------- 6. ENGINE (+ install DLLs into dist)
function Invoke-Engine {
  $eargs = @('-ZigExe', $ZigExe, '-Nvcc', $Nvcc, '-VsBuildTools', $VsBuildTools, '-Jobs', "$Jobs")
  if ($NoClean) { $eargs += '-NoClean' }
  if ($SkipPatches) { $eargs += '-SkipPatches' }
  if ($SkipVideo) { $eargs += '-SkipVideo' }
  & (Join-Path $PSScriptRoot 'scripts\build.ps1') @eargs
  if (-not (Test-Path -LiteralPath $EngineExe)) { throw "engine build finished but $EngineExe is missing" }
  Ok "engine: $EngineExe"
}

# ---------------------------------------------------------------- 7. VERIFY
function Invoke-Verify {
  Say 'VERIFY - engine PE architecture, runtime DLLs, capabilities'
  if (-not (Test-Path -LiteralPath $EngineExe)) { throw "engine missing: $EngineExe" }
  $bytes = [System.IO.File]::ReadAllBytes($EngineExe)
  $pe = [BitConverter]::ToInt32($bytes, 0x3c)
  $machine = [BitConverter]::ToUInt16($bytes, $pe + 4)
  if ($machine -ne 0xaa64) { throw "engine is not ARM64 (machine=0x$($machine.ToString('x4')))" }
  Ok "engine PE machine = ARM64 (0xaa64)"
  $lib = Join-Path $Dist 'native\lib'
  foreach ($name in @('turbojpeg.dll', 'pdfium.dll', 'tfgrammar.dll', 'libwebpdecoder.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $lib $name))) { Miss "runtime DLL not installed in dist: $name" }
  }
  $caps = & $EngineExe capabilities --json | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0) { throw 'capabilities --json failed' }
  Ok "engine=$($caps.engine) version=$($caps.version) chip=$($caps.chip) backends=$($caps.backends)"
}

# ---------------------------------------------------------------- dispatch
if ($PreflightOnly -or $Stage -eq 'preflight') { Invoke-Preflight; return }
Invoke-Preflight
if (Want 'source')   { Invoke-Source }
if (Want 'patches')  { Invoke-Patches }
if (Want 'runtime' -and -not $SkipRuntime) { Invoke-Runtime }
if (Want 'video')    { Invoke-Video }
if (Want 'engine')   { Invoke-Engine }
if (Want 'verify')   { Invoke-Verify }
Say 'OK - Windows ARM64 NVFP4 recipe rebuilt from source'
