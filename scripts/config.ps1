# Shared settings for start.ps1 and stop.ps1 -- the PowerShell port of scripts/config.sh for
# Windows 11 ARM (RTX Spark N1X / GB10 class hardware). A setting's value comes from the first of these that sets it:
#   1. the environment: $env:PORT=9000; .\start.ps1
#   2. .\.env (KEY=value lines, read here, never run)
#
# Windows differences from the bash recipe (all of them are settings or functions below):
#   * there is no container, no image and no build step here: the owner puts the tensorfold-native binary built from
#     TensorFold v1.2.7 + patches 0001..0005 (patches/windows) into $DistDir, and the server is $EngineExe (a plain process) tracked by
#     a PID file and its OpenAI endpoint
#   * the checkpoint is read from the Hugging Face cache snapshot (or $ModelDir when that names a directory), instead
#     of a path inside a container's /root/.cache
#   * no MemAvailable: on a Windows UMA part the memory figure is the CUDA driver's cuMemGetInfo grant
#     (~110 GiB here: the dedicated carveout plus shared system memory), not Windows' Available MBytes,
#     which only sees the CPU side of the partitioned pool (~55 GiB here). WDDM also charges every
#     CUDA allocation against system commit, so start.ps1 checks the commit limit separately.
if (-not $LogName) { $LogName = 'tensorfold' }

# ---------------------------------------------------------------- .env (KEY=value, env wins)
$EnvFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
# Which keys .env actually supplied, so a refusal can name where the value came from: an environment variable survives
# in the window that set it (a `$env:X=0; .\start.ps1` from an earlier attempt is still there), and a `.env` line is
# edited instead. The two need different fixes, and "TENSORFOLD_MEMORY_RESERVE_GIB=0" alone does not say which.
$script:EnvFileKeys = @{}
if (Test-Path -LiteralPath $EnvFile) {
  foreach ($line in (Get-Content -LiteralPath $EnvFile -Encoding UTF8)) {
    if ($line -notmatch '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
    $key = $Matches[2]
    $value = $Matches[3]
    if ($value -match '^"([^"]*)"\s*(#.*)?$' -or $value -match "^'([^']*)'\s*(#.*)?$") {
      $value = $Matches[1]
    } else {
      $value = $value -replace '#.*$', ''
      $value = $value.TrimEnd()
    }
    if ($null -eq [Environment]::GetEnvironmentVariable($key)) {
      Set-Item -Path "Env:$key" -Value $value
      $script:EnvFileKeys[$key.ToUpperInvariant()] = $true
    }
  }
}

function Get-EnvOr {
  # ${VAR:-default}: an empty variable counts as unset, as in bash.
  param([string]$Name, [string]$Default)
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrEmpty($value)) { return $Default }
  return $value
}

function Get-SettingSource {
  # Where the process's value for $Name came from, as the sentence a refusal ends with.
  param([string]$Name)
  if ($script:EnvFileKeys.ContainsKey($Name.ToUpperInvariant())) { return 'It comes from .env (edit that line).' }
  if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($Name))) { return 'It is this recipe''s default.' }
  return ('It is set in this PowerShell session, and a window keeps what it is given: ' +
          ('`$env:' + $Name + ' = $null`') + ' clears it, and a fresh window does not carry it.')
}

# ---------------------------------------------------------------- colours and messages (config.sh parity)
# They come before the settings: a setting that is wrong is refused while this file loads, and the refusal is `die`.
$script:OnConsole = -not [Console]::IsOutputRedirected
$script:AnsiReset = ''
if ($script:OnConsole) { $script:AnsiReset = "$([char]27)[0m" }

function Write-Ansi {
  param([string]$Code, [string]$Text)
  if ($script:OnConsole) { Write-Host "$([char]27)[${Code}m$Text$script:AnsiReset" -NoNewline }
  else { Write-Host $Text -NoNewline }
}

function log {
  param([string]$Message)
  if ($script:OnConsole) { Write-Ansi '1;36' "[$LogName]"; Write-Host " $Message" }
  else { Write-Host "[$LogName] $Message" }
}

function warn {
  param([string]$Message)
  $line = "[$LogName] WARN: $Message"
  if ($script:OnConsole) { [Console]::Error.WriteLine("$([char]27)[1;33m$line$([char]27)[0m") }
  else { [Console]::Error.WriteLine($line) }
}

function die {
  param([string]$Message)
  $line = "[$LogName] ERROR: $Message"
  if ($script:OnConsole) { [Console]::Error.WriteLine("$([char]27)[1;31m$line$([char]27)[0m") }
  else { [Console]::Error.WriteLine($line) }
  exit 1
}

# ---------------------------------------------------------------- paths
$RepoRoot = Split-Path -Parent $PSScriptRoot                    # the recipe repository
$EngineDir = Get-EnvOr 'TF_DIR' (Join-Path $RepoRoot 'tensorfold')   # TensorFold's checkout (git)
# Where the built engine lives: native\bin\tensorfold-native.exe, native\lib\tfgrammar.dll (DIST_DIR to move it).
$DistDir = Get-EnvOr 'DIST_DIR' (Join-Path $EngineDir 'dist')
$EngineExe = Join-Path $DistDir 'native\bin\tensorfold-native.exe'
$EngineLibDir = Join-Path $DistDir 'native\lib'
# Windows resolves a DLL's own dependencies through the process PATH, not the DLL's folder. The optional
# decoders in native\lib (libsharpyuv for WebP, FFmpeg DLLs for libtfvideo) need that folder on PATH.
if (($env:PATH -split ';') -notcontains $EngineLibDir) { $env:PATH = "$EngineLibDir;$env:PATH" }
# The server itself is the Zig binary above; it has no Python dependency. The venv is only for the Python vision
# helper that VISION=1 starts alongside it (Pillow/PyAV, the 27-layer tower -- config.sh).
# Do not confuse this with the 27B recipe, whose whole engine was Python.
$VenvPath = Get-EnvOr 'VENV_PATH' (Join-Path $RepoRoot 'venv')
$PythonExe = Join-Path $VenvPath 'Scripts\python.exe'

# ---------------------------------------------------------------- checkpoint
# The default is NVIDIA's quantization-aware-distilled FP4 (NVFP4 routed experts, MXFP8 and bf16 elsewhere, FP8 n-gram
# table, MTP head): nvidia/Qwen3.8-Flash-Next-FP4-Local, ~96 GiB. azampatti's INT4-AutoRound stays available with
# CHECKPOINT=int4; MODEL_DIR overrides the snapshot path (this recipe's Windows default is the local FP4 folder).
# WEIGHTS_GIB is what loading takes of the memory (measured on the Zig engine: 81 GiB with vision on).
$Checkpoint = Get-EnvOr 'CHECKPOINT' 'nvfp4'
$pinRevision = $true
if (Get-EnvOr 'MODEL_ID' '') { $pinRevision = $false }          # a MODEL_ID set by hand takes no preset revision pin
$ModelId = Get-EnvOr 'MODEL_ID' ''
$ModelRevision = Get-EnvOr 'MODEL_REVISION' ''
switch ($Checkpoint) {
  'nvfp4' {
    if (-not $ModelId) { $ModelId = 'nvidia/Qwen3.8-Flash-Next-FP4-Local' }
    if ($pinRevision -and -not $ModelRevision) { $ModelRevision = 'b9ce18a6887e18c089fdea8509a33e63429a3300' }
    $CkptGiB = 96; $WeightsGiB = [int](Get-EnvOr 'WEIGHTS_GIB' '81')
    $QuantLabel = 'NVIDIA FP4 QAD: NVFP4 experts, MXFP8'
  }
  'int4' {
    $CkptGiB = 122; $WeightsGiB = [int](Get-EnvOr 'WEIGHTS_GIB' '66')
    $QuantLabel = 'INT4-AutoRound'
  }
  default { die "CHECKPOINT is nvfp4 or int4, not $Checkpoint" }
}

# ABLIT=1 serves the FP4 checkpoint with drowzeys's Keys "house-qsa" abliteration overlay grafted in (gated, needs an HF
# token; only for the nvfp4 checkpoint at the pinned revision). The model has had safety refusals removed.
$Ablit = Get-EnvOr 'ABLIT' '0'
if ($Ablit -notmatch '^[01]$') { die "ABLIT must be 0 or 1, not $Ablit" }
$AblitId = 'drowzeys/keys-Qwen3.8-Flash-Next-NVFP4-FP4-QAD-house-qsa-L3-47'
$AblitRevision = Get-EnvOr 'ABLIT_REVISION' 'c44f5b92ee3d307b82aab1c55f4cc4ae1d440344'
$AblitSidecar = 'fp4-local/house-qsa-oproj-mxfp8-L3-47.safetensors'
$AblitStockRevision = 'b9ce18a6887e18c089fdea8509a33e63429a3300'
if ($Ablit -eq '1') {
  if ($Checkpoint -ne 'nvfp4' -or -not $pinRevision -or $ModelRevision -ne $AblitStockRevision) {
    die "ABLIT=1 grafts onto $ModelId @ $($AblitStockRevision.Substring(0,8)) (CHECKPOINT=nvfp4, no MODEL_ID or MODEL_REVISION of your own)"
  }
  $QuantLabel = "$QuantLabel + Keys house-qsa ablit"
}

# The engine binary itself is built separately by the owner (see start.ps1 step 1); no build settings live here.

# ---------------------------------------------------------------- serving (config.sh parity)
$ServedName = Get-EnvOr 'SERVED_NAME' 'Qwen3.8-Flash-Next'
$BindHost = Get-EnvOr 'HOST' '0.0.0.0'          # $Host is a read-only automatic variable in the shell
$Port = [int](Get-EnvOr 'PORT' '8888')
# Native window 262,144; TensorFold 1.2.7's Flash Next CUDA engine has no YaRN extension.
$Context = [int](Get-EnvOr 'CONTEXT' '262144')
$Parallel = [int](Get-EnvOr 'PARALLEL' '5')
$MaxTokens = [int](Get-EnvOr 'MAX_TOKENS' '32768')
$Thinking = Get-EnvOr 'THINKING' '1'
$Drafts = Get-EnvOr 'DRAFTS' '1'
$Temperature = Get-EnvOr 'TEMPERATURE' '1.0'
$TopP = Get-EnvOr 'TOP_P' '0.95'
$TopK = Get-EnvOr 'TOP_K' '20'
$KvDtype = Get-EnvOr 'KV_DTYPE' 'fp8'
$Vision = Get-EnvOr 'VISION' '1'
$VisionUrls = Get-EnvOr 'VISION_URLS' '0'
$Video = Get-EnvOr 'VIDEO' '0'
$Pdf = Get-EnvOr 'PDF' '0'
$MaxVideos = Get-EnvOr 'MAX_VIDEOS' '4'
$env:TF_FLASHNEXT_CHUNK = Get-EnvOr 'TF_FLASHNEXT_CHUNK' '3072'
$env:TF_FLASHNEXT_DRAFTS = Get-EnvOr 'TF_FLASHNEXT_DRAFTS' '6'
$env:TF_FLASHNEXT_SAMPLED_HEADS = Get-EnvOr 'TF_FLASHNEXT_SAMPLED_HEADS' '1'
$env:TF_FLASHNEXT_KEEP_LATE = Get-EnvOr 'TF_FLASHNEXT_KEEP_LATE' '1'
$env:TF_FLASHNEXT_SHARED_SIDE = Get-EnvOr 'TF_FLASHNEXT_SHARED_SIDE' '1'
$env:TF_FLASHNEXT_GDN_LANES = Get-EnvOr 'TF_FLASHNEXT_GDN_LANES' '1'
$env:TF_FLASHNEXT_WARM_AHEAD = Get-EnvOr 'TF_FLASHNEXT_WARM_AHEAD' '1'
$env:TF_FLASHNEXT_PROMPT_EXPERT_TILE = Get-EnvOr 'TF_FLASHNEXT_PROMPT_EXPERT_TILE' '2'
$env:TF_FLASHNEXT_PROMPT_MX128 = Get-EnvOr 'TF_FLASHNEXT_PROMPT_MX128' '1024'
$env:TF_FLASHNEXT_CONFIDENCE = Get-EnvOr 'TF_FLASHNEXT_CONFIDENCE' '-0.4'
$env:TF_FLASHNEXT_SHARED_DRAFTS = Get-EnvOr 'TF_FLASHNEXT_SHARED_DRAFTS' '0'
$env:TF_FLASHNEXT_DRAFT_HEAD = Get-EnvOr 'TF_FLASHNEXT_DRAFT_HEAD' 'affine4'
$env:TENSORFOLD_MAX_IMAGES = Get-EnvOr 'TENSORFOLD_MAX_IMAGES' '50'
$env:TENSORFOLD_IMAGE_TOKENS = Get-EnvOr 'TENSORFOLD_IMAGE_TOKENS' '16384'
$env:TENSORFOLD_VIDEO_TOKENS = Get-EnvOr 'TENSORFOLD_VIDEO_TOKENS' '16384'
$env:TENSORFOLD_VISION_WORKSPACE_MIB = Get-EnvOr 'TENSORFOLD_VISION_WORKSPACE_MIB' '2048'
# Windows runtime libraries live in dist\native\lib. v1.2.7's built-in Windows WebP candidate name is
# wrong (it still looks for libwebpdecoder.so.3), so TENSORFOLD_LIBWEBP must name the DLL explicitly.
$env:TENSORFOLD_LIBTURBOJPEG = Get-EnvOr 'TENSORFOLD_LIBTURBOJPEG' (Join-Path $EngineLibDir 'turbojpeg.dll')
$env:TENSORFOLD_LIBWEBP = Get-EnvOr 'TENSORFOLD_LIBWEBP' (Join-Path $EngineLibDir 'libwebpdecoder.dll')
$env:TENSORFOLD_LIBPDFIUM = Get-EnvOr 'TENSORFOLD_LIBPDFIUM' (Join-Path $EngineLibDir 'pdfium.dll')
$env:TENSORFOLD_MEMORY_RESERVE_GIB = Get-EnvOr 'TENSORFOLD_MEMORY_RESERVE_GIB' '9'
# The conservative stream preflight is a warning on this Windows build (patch 0006): unified memory
# can serve loads the engine's fixed reserve says no to. Set to 0 to restore the hard refusal.
$env:TENSORFOLD_IGNORE_STREAM_BUDGET = Get-EnvOr 'TENSORFOLD_IGNORE_STREAM_BUDGET' '1'
# The engine validates this itself; on an integrated GPU 2 GiB is the floor. A lower value is
# raised to 2 with a warning instead of failing the whole start.
$reserveText = "$env:TENSORFOLD_MEMORY_RESERVE_GIB"
$reserveParsed = 0.0
if (-not [double]::TryParse($reserveText, [ref]$reserveParsed)) {
  die ("TENSORFOLD_MEMORY_RESERVE_GIB=$reserveText is not a number of GiB, so the engine would refuse it at load. " +
       (Get-SettingSource 'TENSORFOLD_MEMORY_RESERVE_GIB'))
}
if ($reserveParsed -lt 2) {
  warn ("TENSORFOLD_MEMORY_RESERVE_GIB=$reserveText is under the 2 GiB floor an integrated GPU keeps and the engine would stop the load over it: this start uses 2 instead. " +
        (Get-SettingSource 'TENSORFOLD_MEMORY_RESERVE_GIB'))
  $env:TENSORFOLD_MEMORY_RESERVE_GIB = '2'
}
$env:TENSORFOLD_NO_UPDATE_CHECK = Get-EnvOr 'TENSORFOLD_NO_UPDATE_CHECK' '1'
$env:HF_HUB_OFFLINE = Get-EnvOr 'HF_HUB_OFFLINE' '1'

# ---------------------------------------------------------------- the load pipeline (load speed)
# Engine boundary: this recipe serves tensorfold-native (Zig, v1.1.4 + the 18 patches here). The 27B recipe used the
# Python engine at v0.6.0; its patches/0007-unified-memory-load-pipeline.patch rewrites Python files (direct_read.py,
# load_pipeline.py) and defines TENSORFOLD_LOAD_THREADS / _RUN_MIB / _GAP_MIB / _STATS / _SERIAL. None of those names
# exists anywhere in tensorfold-native, so exporting them here would be dead configuration and is deliberately NOT done.
# The principle still holds on a unified-memory part (a host->device copy is DRAM->DRAM: fewer, larger round trips beat
# raw bandwidth), but an equivalent change has to be made in the Zig reader, not in these scripts:
#   * zig/src/core/safetensors.zig maps each shard with MemoryMap.create(.populate = false) and get() returns a slice
#     of that mapping, so the upload walks the file through demand faults rather than large sequential reads.
#   * File.release() is a no-op off Linux (madvise/POSIX_FADV_DONTNEED are Linux-only), so on Windows the mapped pages
#     are not dropped after load and keep competing with the engine's allocations for the same DRAM.
#   * zig/src/families/flashnext/load_weights.zig and cuda_*_load.zig stage per-tensor conversions: pinned staging and
#     a side-stream upload, if added, belong there.
# What these scripts can do without an engine patch: measure it. start.ps1's step 4 prints GiB/s while the weights load
# and the average at ready, so any change to that Zig read path can be compared on this machine. Three machine-level
# choices are left to the owner, not applied here: the checkpoint on a local NVMe volume (not a network share), no NTFS
# compression on the cache folder (`compact /u`), and an antivirus real-time exclusion for the HF cache. A scanner that
# opens each of the ~96 GiB of reads is the single largest load-time cost on Windows, and that policy is the owner's.

# ---------------------------------------------------------------- memory
# The engine keeps this much free when it sizes the KV pool; start.ps1 refuses a machine below it.
$MemFloorGiB = [int](Get-EnvOr 'MEM_FLOOR_GIB' "$($env:TENSORFOLD_MEMORY_RESERVE_GIB)")
$MemNeedGiB = Get-EnvOr 'MEM_NEED_GIB' ''
$MemCheck = Get-EnvOr 'MEM_CHECK' '1'
# RTX Spark N1X / GB10 is a Windows UMA part: nvidia-smi's "FB Memory Usage" is only the dedicated
# carveout (64 GiB here), while cuMemGetInfo grants ~110 GiB including shared system memory. The
# engine admits against cuMemGetInfo (zig/src/cuda/context.zig), so that is what these checks use.
# CUDA_BUDGET_GIB overrides the probe. WDDM charges CUDA allocations against system commit
# (NVIDIA developer forums 386453 / 387069); COMMIT_CHECK=0 silences that warning.
$CudaBudgetOverrideGiB = Get-EnvOr 'CUDA_BUDGET_GIB' ''
$CommitCheck = Get-EnvOr 'COMMIT_CHECK' '1'

function Get-KvGiB {
  # One full sequence's cache at TP=1: bf16 30,784 bytes a token, fp8 17,888 (keys carry both scales).
  param([int]$Tokens = $Context)
  $bytes = 30784
  if ($KvDtype -eq 'fp8') { $bytes = 17888 }
  return [int][math]::Ceiling(($bytes * $Tokens) / 1073741824.0)
}

function Get-MemNeedGiB {
  # What a start needs: weights, one full window, 8 GiB scratch slack, the vision workspace, the floor, 2 GiB.
  param([int]$Tokens = $Context)
  $vision = 0
  if ($Vision -eq '1') { $vision = 2 }
  return ($WeightsGiB + (Get-KvGiB $Tokens) + 8 + $vision + $MemFloorGiB + 2)
}

function Invoke-Native {
  # Run a tool with its stderr treated as data: under $ErrorActionPreference = 'Stop' a single warning line on stderr
  # (git's, nvidia-smi's, zig's) would become a terminating error, and these scripts shell out constantly.
  param([string]$Exe, [string[]]$Arguments = @(), [switch]$Stream)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Stream) {
      & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
      return [pscustomobject]@{ Code = $LASTEXITCODE; Lines = @(); Text = '' }
    }
    $output = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $lines = @($output | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n") }
  } finally {
    $ErrorActionPreference = $previous
  }
}

function Get-CommandPath {
  param([string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  return ''
}

# ---------------------------------------------------------------- cache, state and log directories
$HfCache = Get-EnvOr 'HF_CACHE' (Join-Path $env:USERPROFILE '.cache\huggingface')
# The engine's kernel cache and the per-machine log directory: what the image's CUDA_CACHE_PATH=/cache was.
$KernelCache = Get-EnvOr 'KERNEL_CACHE' (Join-Path $env:USERPROFILE '.cache\tensorfold-qwen38')
$env:CUDA_CACHE_PATH = Join-Path $KernelCache 'nv'
$StateDir = Get-EnvOr 'STATE_DIR' (Join-Path $env:USERPROFILE '.local\state\qwen38-flash-next-tf')
$LogDir = Get-EnvOr 'LOG_DIR' (Join-Path $KernelCache 'logs')
$LogKeep = [int](Get-EnvOr 'LOG_KEEP' '10')
# A plain checkpoint directory (no Hub cache): when it holds a config.json it wins over the snapshot path.
# Default: nvidia/Qwen3.8-Flash-Next-FP4-Local, downloaded by scripts\download-model.ps1 straight into this
# folder (ModelScope mirror nv-community/Qwen3.8-Flash-Next-FP4-Local). The layout is flat config.json +
# tensors\*.safetensors + tokenizer files, with no .git, no snapshot cache and no symlinks. Set MODEL_DIR
# to any other path to override; Get-CheckpointDir uses it as soon as it contains a config.json.
$ModelSource = Get-EnvOr 'MODEL_SOURCE' 'nv-community/Qwen3.8-Flash-Next-FP4-Local'
$ModelDir = Get-EnvOr 'MODEL_DIR' 'D:\llm\models\Qwen3.8-Flash-Next-FP4-Local'

# ---------------------------------------------------------------- the checkpoint's location
function Get-ModelCacheDir {
  param([string]$RepoId)
  return (Join-Path $HfCache ("hub\models--" + ($RepoId -replace '/', '--')))
}

function Get-SnapshotRev {
  if ($ModelRevision) { return $ModelRevision }
  $ref = Join-Path (Get-ModelCacheDir $ModelId) 'refs\main'
  if (Test-Path -LiteralPath $ref) { return (Get-Content -LiteralPath $ref -Raw).Trim() }
  return ''
}

function Get-AblitViewSub {
  return ("tensorfold-qwen38\ablit-" + $ModelRevision.Substring(0, 8) + "-" + $AblitRevision.Substring(0, 8))
}

function Get-ModelSub {
  # The folder under $HfCache the engine reads: the ABLIT view when ABLIT=1, else the snapshot.
  if ($Ablit -eq '1') { return (Get-AblitViewSub) }
  return ("hub\models--" + ($ModelId -replace '/', '--') + "\snapshots\" + (Get-SnapshotRev))
}

function Get-CheckpointDir {
  # The directory `tensorfold-native serve` gets: $ModelDir when it holds a checkpoint, else the cache path.
  if ($ModelDir -and (Test-Path -LiteralPath (Join-Path $ModelDir 'config.json'))) { return $ModelDir }
  return (Join-Path $HfCache (Get-ModelSub))
}

# The recipe's patches and the built engine's identity are the owner's concern; no marker is tracked here.

# ---------------------------------------------------------------- the machine
function Get-AvailableGiB {
  # Available MBytes (free plus standby: the closest thing to MemAvailable), else the bare free figure.
  try {
    $counter = Get-Counter -Counter '\Memory\Available MBytes' -ErrorAction Stop
    return [int][math]::Floor($counter.CounterSamples[0].CookedValue / 1024)
  } catch {
    try {
      $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
      return [int][math]::Floor(($os.FreePhysicalMemory) / 1MB)
    } catch { return 0 }
  }
}

function Get-CudaProbePath {
  # cuMemGetInfo is the only figure on a Windows UMA part that matches what the engine allocates
  # against. Write a tiny ctypes probe once into the cache directory: no Add-Type, no third-party
  # module, no PowerShell 7-only API, so this works in both 5.1 and 7.
  $probe = Join-Path $KernelCache 'cuda_probe.py'
  if (Test-Path -LiteralPath $probe) { return $probe }
  $source = (@(
    'import ctypes, sys'
    'd = ctypes.CDLL("nvcuda.dll")'
    'if d.cuInit(0): sys.exit(2)'
    'dev = ctypes.c_int(0)'
    'if d.cuDeviceGet(ctypes.byref(dev), 0): sys.exit(3)'
    'ctx = ctypes.c_void_p()'
    'if d.cuDevicePrimaryCtxRetain(ctypes.byref(ctx), dev): sys.exit(4)'
    'if d.cuCtxSetCurrent(ctx): sys.exit(5)'
    'free = ctypes.c_size_t(0)'
    'total = ctypes.c_size_t(0)'
    'if d.cuMemGetInfo_v2(ctypes.byref(free), ctypes.byref(total)): sys.exit(6)'
    'print("%d %d" % (free.value, total.value))'
    'd.cuDevicePrimaryCtxRelease(dev)'
  )) -join "`n"
  try {
    New-Item -ItemType Directory -Force -Path $KernelCache | Out-Null
    Set-Content -LiteralPath $probe -Value $source -Encoding ascii
    return $probe
  } catch { return '' }
}

function Get-CudaMemoryBytes {
  # [free, total] in bytes as the CUDA driver grants them, or $null when it cannot be queried.
  $python = $PythonExe
  if (-not (Test-Path -LiteralPath $python)) { $python = Get-CommandPath 'python' }
  if (-not $python) { return $null }
  $probe = Get-CudaProbePath
  if (-not $probe) { return $null }
  $result = Invoke-Native $python @($probe)
  if ($result.Code -ne 0) { return $null }
  $parts = "$($result.Text)".Trim() -split '\s+'
  if ($parts.Count -lt 2) { return $null }
  try { return @([uint64]$parts[0], [uint64]$parts[1]) } catch { return $null }
}

function Get-CudaBudgetGiB {
  # Free CUDA memory in GiB. -1 when neither the probe nor nvidia-smi answers.
  if ($CudaBudgetOverrideGiB) { return [int]$CudaBudgetOverrideGiB }
  $bytes = Get-CudaMemoryBytes
  if ($bytes -and $bytes.Count -ge 2) { return [int][math]::Floor($bytes[0] / 1073741824) }
  # Last resort: nvidia-smi's FB free is only the carveout on UMA and understates the grant.
  $result = Invoke-Native 'nvidia-smi' @('--query-gpu=memory.total,memory.used', '--format=csv,noheader,nounits')
  if ($result.Code -ne 0) { return -1 }
  $free = 0.0
  foreach ($line in $result.Lines) {
    if ("$line" -match '^\s*([0-9.]+)\s*,\s*([0-9.]+)\s*$') {
      $free += ([double]$Matches[1] - [double]$Matches[2])
    }
  }
  return [int][math]::Floor($free / 1024)
}

function Get-EffectiveGiB {
  # The engine's admission figure ONLY: free CUDA memory from cuMemGetInfo (zig/src/cuda/context.zig).
  # On a Windows UMA part it includes the dedicated carveout plus shared system memory (~110 GiB);
  # Windows' Available MBytes only sees the CPU side (~55 GiB here), and taking the min of the two
  # was the 55 GiB false alarm. This is NOT "physical GPU memory left": WDDM expands the shared pool
  # on demand, so cuMemGetInfo free stays high while committed memory climbs. For reporting real
  # occupancy use Get-GpuUsedGiB / Get-GpuFreeGiB (WDDM counters, what Task Manager shows).
  $cudaFree = Get-CudaBudgetGiB
  if ($cudaFree -ge 0) { return $cudaFree }
  return Get-AvailableGiB
}

function Get-CommitFreeGiB {
  # WDDM backs every CUDA allocation with system commit (NVIDIA developer forums 386453 / 387069).
  # With a 64 GiB carveout the host sees ~64 GiB, so a small page file caps the commit limit below
  # the ~81 GiB of weights even while CUDA reports ~110 GiB free. A larger page file (initial
  # 98304 MB, maximum 131072 MB) plus a reboot lifts the cap; nothing is really written to disk.
  try {
    $samples = (Get-Counter -Counter '\Memory\Commit Limit','\Memory\Committed Bytes' -ErrorAction Stop).CounterSamples
    $limit = [double]0
    $used = [double]0
    foreach ($sample in $samples) {
      if ("$($sample.Path)" -match 'commit limit$') { $limit = [double]$sample.CookedValue }
      elseif ("$($sample.Path)" -match 'committed bytes$') { $used = [double]$sample.CookedValue }
    }
    if ($limit -le 0) { return -1 }
    return [int][math]::Floor(($limit - $used) / 1073741824)
  } catch {
    try {
      $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
      return [int][math]::Floor($os.FreeVirtualMemory / 1MB)
    } catch { return -1 }
  }
}

function Get-GpuCommittedBytes {
  # WDDM's own accounting: what Task Manager shows as "GPU memory" (dedicated carveout plus shared
  # system memory) and as Dedicated/Shared Usage on the Performance tab. cuMemGetInfo's total-free
  # is NOT this number: on a UMA part WDDM grows the shared pool as the engine allocates, so free
  # stays near total and their difference stays near zero even while 78 GiB is committed. That is
  # why the old heartbeat printed "0.2 GiB in use" while Task Manager read 65/110 GB.
  try {
    $samples = (Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage',
                                     '\GPU Adapter Memory(*)\Shared Usage' -ErrorAction Stop).CounterSamples
    $used = [double]0
    foreach ($sample in $samples) { $used += [double]$sample.CookedValue }
    if ($used -gt 0) { return [uint64]$used }
  } catch { }
  return [uint64]0
}

function Get-GpuUsedGiB {
  # Real committed GPU memory in GiB, for the loading heartbeat and the GiB/s readout.
  param([string]$Format = 'F1')
  $used = Get-GpuCommittedBytes
  if ($used -gt 0) { return ('{0:F1}' -f ($used / 1073741824.0)) }
  $result = Invoke-Native 'nvidia-smi' @('--query-gpu=memory.used', '--format=csv,noheader,nounits')
  if ($result.Code -ne 0) { return ('{0:F1}' -f 0) }
  $mib = 0.0
  foreach ($line in $result.Lines) {
    $text = "$line".Trim()
    if ($text -match '^[0-9.]+$') { $mib += [double]$text }
  }
  return ('{0:F1}' -f ($mib / 1024))
}

function Get-GpuFreeGiB {
  # Remaining room in the ~110 GiB WDDM pool (cuMemGetInfo's total is the WDDM ceiling here).
  # This is what Task Manager's "65/110 GB" leaves over. Get-EffectiveGiB is a different figure:
  # the CUDA driver's allocation budget, used only for the start admission test.
  $used = Get-GpuCommittedBytes
  $bytes = Get-CudaMemoryBytes
  if ($used -gt 0 -and $bytes -and $bytes.Count -ge 2) {
    $free = [double]$bytes[1] - [double]$used
    if ($free -lt 0) { $free = 0 }
    return [int][math]::Floor($free / 1073741824)
  }
  return Get-CudaBudgetGiB
}

function Test-PortListening {
  param([int]$PortNumber)
  try {
    # A listener whose owner is already gone keeps its PID 0 row for a few seconds after a killed
    # server; treating it as busy blocks the restart that would reuse the port.
    $found = @(Get-NetTCPConnection -LocalPort $PortNumber -State Listen -ErrorAction Stop |
      Where-Object { $_.OwningProcess -ne 0 })
    return ($found.Count -gt 0)
  } catch {
    foreach ($line in @(netstat -ano 2>$null | Select-String -Pattern 'LISTENING')) {
      if ("$line" -notmatch "[:.]$PortNumber\s") { continue }
      if ("$line" -match '\s0\s*$') { continue }   # dead owner, the kernel is dropping the row
      return $true
    }
    return $false
  }
}

function Get-PortOwner {
  param([int]$PortNumber)
  try {
    $conn = Get-NetTCPConnection -LocalPort $PortNumber -State Listen -ErrorAction Stop | Select-Object -First 1
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return "$($proc.ProcessName) (PID $($proc.Id))" }
  } catch { }
  return 'unknown process'
}

# ---------------------------------------------------------------- the start lock (start.sh's flock -n 8)
# start.sh does `exec 8>"$STATE_DIR/start.lock"; flock -n 8`: an advisory lock the kernel drops when the
# owning process dies. The first Windows port used a FileStream opened with FileShare.None instead. Those
# are NOT equivalent: `.\start.ps1` in an interactive shell ends with `exit`, which stops the SCRIPT but
# leaves pwsh.exe alive; a die() before the handle was disposed therefore left the lock held by that
# shell, and every later start.ps1 failed with "another start.ps1 is already running" while stop.ps1
# (which only tracks the server's PID) could not clear it. A named kernel mutex has flock's semantics:
# WaitOne(0) is the non-blocking flock -n, the OS releases it when the holder dies, and an abandoned
# mutex is acquired by the next caller. The 0-byte start.lock / prepare.lock files still in $StateDir
# are inert leftovers from the old scheme and are no longer used.
$StartLockFile = Join-Path $StateDir 'start.lock'      # legacy, diagnostics only
$StartOwnerFile = Join-Path $StateDir 'start.owner'    # "pid|utc" of the run holding the mutex

function Get-StartLockNames {
  # The lock belongs to THIS recipe, not to the machine. Its name is derived from $RepoRoot and it
  # lives in the session-private Local\ namespace. Global\ was a mistake: it is machine-wide, so a
  # start.ps1 in one model project locked out start.ps1 in every other project on the same box.
  # Local\ still serialises all terminal windows of this login, which is what flock -n 8 did.
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes("$RepoRoot".ToUpperInvariant())
  $tag = ([System.BitConverter]::ToString($md5.ComputeHash($bytes)) -replace '-', '').Substring(0, 8)
  $md5.Dispose()
  $base = "TensorFold-Start-$tag"
  if ((Get-EnvOr 'FORCE_LOCK' '0') -eq '1') { $base = "$base-force-$PID" }
  return @("Local\$base")
}

function Get-StartLockOwner {
  if (-not (Test-Path -LiteralPath $StartOwnerFile)) { return '' }
  $text = Get-Content -LiteralPath $StartOwnerFile -Raw -ErrorAction SilentlyContinue
  if ($null -eq $text) { return '' }
  return "$text".Trim()
}

function Set-StartLockOwner {
  param([string]$Text)
  try { Set-Content -LiteralPath $StartOwnerFile -Value $Text -Encoding ascii -ErrorAction Stop } catch { }
}

function Clear-StartLockOwner {
  # Write an empty record instead of deleting the file: no delete races with another start.ps1.
  Set-StartLockOwner ''
}

function Test-StartLockHeld {
  # True when a start.ps1 in another process owns the mutex. stop.ps1 uses this to report a stuck run
  # instead of looking like an unlock that never happened.
  foreach ($name in (Get-StartLockNames)) {
    $m = $null
    $held = $false
    try {
      $m = New-Object System.Threading.Mutex($false, $name)
      try { $held = -not $m.WaitOne(0) }
      catch [System.Threading.AbandonedMutexException] { $held = $false }
      if (-not $held) { try { $m.ReleaseMutex() } catch { } }
      return $held
    } catch { }
    finally { if ($m) { $m.Dispose() } }
  }
  return $false
}

# ---------------------------------------------------------------- the server process (no container)
$PidFile = Join-Path $StateDir 'server.pid'
$LogPointer = Join-Path $StateDir 'server.logs'

function Get-ServerProcess {
  # The launcher (cmd.exe) whose child is tensorfold-native, while it is alive. Killing it with /T ends the server.
  if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
  $text = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
  if (-not $text) { return $null }
  $serverPid = 0
  if (-not [int]::TryParse("$text".Trim(), [ref]$serverPid)) { return $null }
  $proc = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  return $proc
}

function Test-ServerRunning {
  return [bool](Get-ServerProcess)
}

function Stop-Server {
  # Windows has no SIGTERM for a console process: the whole process tree is terminated with taskkill /T.
  param([int]$TimeoutSeconds = 30)
  $proc = Get-ServerProcess
  if (-not $proc) {
    Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
    return $false
  }
  Invoke-Native 'taskkill' @('/PID', "$($proc.Id)", '/T', '/F') | Out-Null
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
  }
  Remove-Item -LiteralPath $PidFile -ErrorAction SilentlyContinue
  return $true
}

function Get-ApiBaseUrl {
  # Where to reach the server from this machine: a wildcard bind answers on loopback.
  $apiHost = $BindHost
  if ($BindHost -eq '0.0.0.0' -or $BindHost -eq '::') { $apiHost = '127.0.0.1' }
  if ($apiHost -match ':') { $apiHost = "[$apiHost]" }
  return "http://${apiHost}:$Port"
}

function Invoke-LocalRest {
  # The loopback REST helper from the Windows ARM64 port notes: every call spells out -Method
  # (PS 5.1 otherwise sends a bodyless POST and refuses it) and never goes through a proxy.
  # Without it /health answers 200 in the engine log while start.ps1 waits out WAIT_TIMEOUT.
  param([string]$Uri, [int]$TimeoutSec = 5, [string]$Method = 'Get', [string]$Body = '')
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    if (-not [string]::IsNullOrEmpty($Body)) {
      return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop
    }
    return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop
  }
  $old = [System.Net.WebRequest]::DefaultWebProxy
  [System.Net.WebRequest]::DefaultWebProxy = $null
  try {
    if (-not [string]::IsNullOrEmpty($Body)) {
      return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -ErrorAction Stop
    }
    return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -ErrorAction Stop
  } finally { [System.Net.WebRequest]::DefaultWebProxy = $old }
}

function Invoke-Api {
  param([string]$Path, [int]$TimeoutSeconds = 5)
  try { return Invoke-LocalRest -Uri "$(Get-ApiBaseUrl)$Path" -TimeoutSec $TimeoutSeconds -Method 'Get' }
  catch { return $null }
}

function Test-ApiReady {
  return [bool](Invoke-Api '/health' 5)
}

function Get-ServedName {
  $models = Invoke-Api '/v1/models' 5
  if ($models -and $models.data -and $models.data.Count -gt 0) { return $models.data[0].id }
  return ''
}

function Get-LanAddress {
  if ($BindHost -ne '0.0.0.0' -and $BindHost -ne '::') { return $BindHost }
  try {
    $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
      Select-Object -First 1
    if ($address) { return $address.IPAddress }
  } catch { }
  return 'localhost'
}
