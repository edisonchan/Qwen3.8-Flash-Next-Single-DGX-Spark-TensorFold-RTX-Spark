# Build TensorFold's Zig engine for Windows ARM64 (sm_121) and install it into <project>\tensorfold\dist.
# Uses the local Zig 0.17 toolchain, VS2022 Build Tools' ARM64 DevShell and CUDA 13.4 nvcc.
# Applies the Windows-normalized recipe patches first; removes .zig-cache / zig-out / CUDA scratch after
# a successful build, so the checkout stays source-only and the only build output is tensorfold\dist.
param(
  [string]$ZigExe = 'D:\building\zig-aarch64-windows-0.17.0\zig.exe',
  [string]$Nvcc = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin\nvcc.exe',
  [string]$VsBuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
  [string]$Tensorfold = '',
  [string]$Prefix = '',
  [string]$Sm = '121',
  [int]$Jobs = 0,
  [switch]$NvccSplitCompile,
  [switch]$NoClean,
  [switch]$SkipPatches,
  [switch]$SkipVideo
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $Tensorfold) { $Tensorfold = Join-Path $RepoRoot 'tensorfold' }
if (-not $Prefix) { $Prefix = Join-Path $Tensorfold 'dist' }
$TfRepo = 'https://github.com/ashhart/TensorFold.git'
$TfRef = '93a2e93ecebff8aa52b88e58c5dd222516e69c5f'   # v1.2.7, the pin in scripts/config.sh
$git = (Get-Command git.exe -ErrorAction Stop).Source
# Zig limits concurrent build steps with -jN (it already defaults to all cores; make the 20-core intent explicit).
if ($Jobs -le 0) { $Jobs = [int](${env:NUMBER_OF_PROCESSORS}) ; if ($Jobs -le 0) { $Jobs = 20 } }

function Say { param([string]$Message) Write-Host "[build] $Message" }

# ---------------------------------------------------------------- 1. source checkout inside the project
if (-not (Test-Path -LiteralPath (Join-Path $Tensorfold 'build.zig'))) {
  Say "fetching TensorFold $TfRef into $Tensorfold"
  New-Item -ItemType Directory -Force -Path $Tensorfold | Out-Null
  & $git -C $Tensorfold init -q
  & $git -C $Tensorfold remote remove origin 2>$null
  & $git -C $Tensorfold remote add origin $TfRepo
  & $git -C $Tensorfold fetch -q --depth 1 origin $TfRef
  & $git -C $Tensorfold checkout -q --detach FETCH_HEAD
}
& $git -C $Tensorfold config core.autocrlf false
$head = (& $git -C $Tensorfold rev-parse HEAD).Trim()
if ($head -ne $TfRef) { Say "WARNING: checkout is $head, recipe patches target $TfRef" }
Say "TensorFold $head"

# ---------------------------------------------------------------- 2. patches (LF-normalized Windows copies)
if (-not $SkipPatches) {
  & (Join-Path $PSScriptRoot 'apply-patches.ps1') -Tensorfold $Tensorfold
  if ($LASTEXITCODE -ne 0) { throw 'apply-patches.ps1 failed' }
}

# ---------------------------------------------------------------- 3. toolchain
foreach ($pair in @(@('Zig', $ZigExe), @('nvcc', $Nvcc))) {
  if (-not (Test-Path -LiteralPath $pair[1])) { throw "$($pair[0]) not found: $($pair[1])" }
}
$devShellDll = Join-Path $VsBuildTools 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
if (-not (Test-Path -LiteralPath $devShellDll)) { throw "VS2022 DevShell not found: $devShellDll" }
foreach ($name in @('https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY')) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
Import-Module $devShellDll
Enter-VsDevShell -VsInstallPath $VsBuildTools -DevCmdArguments '-arch=arm64 -host_arch=arm64' -SkipAutomaticLocation | Out-Null
$env:PATH = "$(Split-Path -Parent $Nvcc);$env:PATH"
# Patch 0008 adds /Zc:preprocessor and /utf-8 to every nvcc call and understands this opt-in switch.
# nvcc's --threads only helps multi-architecture builds (we emit one sm_121); --split-compile does use
# internal threads, but combining it with -j20 oversubscribes 20 cores. Use -Jobs 4 -NvccSplitCompile
# if you prefer fewer, fatter nvcc processes.
if ($NvccSplitCompile) {
  if ($Jobs -gt 6) { Say "WARNING: -NvccSplitCompile with -j$Jobs oversubscribes the CPU; consider -Jobs 4" }
  $env:TENSORFOLD_NVCC_SPLIT_COMPILE = '1'
} else {
  $env:TENSORFOLD_NVCC_SPLIT_COMPILE = '0'
}
$cudaScratch = Join-Path $RepoRoot '.work\cuda-cache'
$env:CUDA_CACHE_PATH = $cudaScratch
New-Item -ItemType Directory -Force -Path $cudaScratch, $Prefix | Out-Null
Say "cl   = $((Get-Command cl.exe -ErrorAction Stop).Source)"
Say "nvcc = $((Get-Command nvcc.exe -ErrorAction Stop).Source)"

# ---------------------------------------------------------------- 4. build and install
New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot '.work') | Out-Null
$log = Join-Path $RepoRoot '.work\build.log'
Say "zig build -j$Jobs native install -Dsm=$Sm -Doptimize=fast -Dstrip=true --prefix $Prefix"
$old = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Push-Location $Tensorfold
try {
  & $ZigExe build "-j$Jobs" native install "-Dnvcc=$Nvcc" -Doptimize=fast -Dstrip=true "-Dsm=$Sm" --prefix $Prefix *> $log
  $rc = $LASTEXITCODE
} finally {
  Pop-Location
  $ErrorActionPreference = $old
}
if ($rc -ne 0) {
  Get-Content -LiteralPath $log -Tail 60
  throw "zig build failed (exit $rc); see $log"
}
$exe = Join-Path $Prefix 'native\bin\tensorfold-native.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "build finished but $exe is missing" }
$docDir = Join-Path $Prefix 'share\doc\tensorfold'
New-Item -ItemType Directory -Force -Path $docDir | Out-Null
foreach ($name in @('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md')) {
  $source = Join-Path $Tensorfold $name
  if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $docDir -Force }
}

# ---------------------------------------------------------------- 5. optional runtime libraries
if (-not $SkipVideo) {
  & (Join-Path $PSScriptRoot 'build-video.ps1') -ZigExe $ZigExe -Tensorfold $Tensorfold -Prefix $Prefix -Jobs $Jobs
} else {
  Say 'video/runtime DLL step skipped (-SkipVideo)'
}

# ---------------------------------------------------------------- 6. clean intermediate files
if (-not $NoClean) {
  # git clean removes thousands of cache files in one operation and leaves dist/ untouched
  # (its pathspec names only the two Zig cache directories).
  foreach ($dir in @('.zig-cache', 'zig-out')) {
    $full = Join-Path $Tensorfold $dir
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $done = $false
    try {
      & $git -C $Tensorfold clean -fdx -- $dir 2>&1 | Out-Null
      $done = ($LASTEXITCODE -eq 0)
    } catch { $done = $false }
    if (-not $done) { Remove-Item -LiteralPath $full -Recurse -Force }
    Say "cleaned $full"
  }
  if (Test-Path -LiteralPath $cudaScratch) { Remove-Item -LiteralPath $cudaScratch -Recurse -Force; Say "cleaned $cudaScratch" }
}
Say "OK: $exe"
Say "artifacts: $Prefix (only build output; intermediates removed)"
