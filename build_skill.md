# Build Skill — Qwen3.8-Flash-Next NVFP4 on Windows 11 ARM64 (DGX Spark / GB10, sm_121)

> This file is the build guide for an AI assistant or a human operator. It explains how the
> **source-only** repository is rebuilt into a running engine, stage by stage, what each stage
> needs, and how to diagnose failures. The operator controls all installs: `-PreflightOnly` and
> `-NoAutoSetup` never install anything; the full `build.ps1` only self-heals Zig/VS Build Tools
> when the operator runs it without those switches.

## 0. Fresh-machine quick start — RTX Spark / Windows 11 ARM64

Use this section when the machine has just been installed. Do the steps in order.

### 0.1 Set 128 GB virtual memory FIRST (WDDM)

On Windows, GPU-accessible system memory is managed through the WDDM pagefile. The NVFP4
checkpoint is ~95 GiB; if the pagefile is small, the engine can fail with host-memory / allocation
errors even when Task Manager appears to show free RAM. Configure it **before** loading the model:

1. `Win + R` → `sysdm.cpl` → **Advanced** → **Performance: Settings** → **Advanced** →
   **Virtual memory: Change**.
2. Uncheck **Automatically manage paging file size for all drives**.
3. Select the **fastest NVMe** drive (not a card/removable disk), choose **Custom size**.
4. Set **Initial size = 131072 MB** and **Maximum size = 131072 MB** (128 GiB). If the dialog
   shows GiB instead of MB, enter `128`.
5. Click **Set** → **OK**, then **reboot**.

Verify after reboot:

```powershell
Get-CimInstance Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize
# expect MaximumSize = 131072 on the selected drive
```

Reserve at least **300 GB free** on that drive: 128 GiB pagefile + ~95 GiB model + build scratch.

### 0.2 Driver + CUDA 13.4 (operator installs; build.ps1 only prompts)

1. Install the current NVIDIA driver offered for RTX Spark, reboot, then confirm `nvidia-smi`.
2. Install the **native ARM64** CUDA 13.4 toolkit, not an x64 or Linux package. Use the **GA**
   release (13.4.3), not the 13.4.0 Developer Preview:

   ```
   https://developer.nvidia.com/cuda-13-4-3-download-archive?target_os=Windows&target_arch=arm64&target_version=11&target_type=exe_local
   ```

   The installer is `cuda_13.4.3_windows_arm64.exe` (~3.5 GB). Install default developer
   components, reboot, then confirm in a **new** PowerShell: `nvcc --version`.

`build.ps1` never installs CUDA. If `nvcc.exe` is missing it prints the URL above and stops.

### 0.3 Base tools and repo

Install **native ARM64** `git`, `python`, `curl`, and `tar` (all on `PATH`); avoid x86 tools
running under emulation. Then clone and enter the repository:

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark.git
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

The repository is source-only: `tensorfold/`, `dist/`, and all DLLs are created locally by the
build; there is nothing else to copy in.

### 0.4 Full build (video included by default)

```powershell
# 1. safe detection only — no download, no install
powershell -ExecutionPolicy Bypass -File .\build.ps1 -PreflightOnly

# 2. complete build: source -> patches -> runtime -> video -> engine -> verify
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Everything is built with the native Windows ARM64 toolchain — Zig 0.17.0, VS2022 Build Tools
ARM64 and CUDA nvcc. There is no MSYS2, no conda and no cross toolchain anywhere in the recipe.
Missing Zig is downloaded automatically; missing VS2022 Build Tools ARM64 is installed by the
official silent command (run elevated, then reopen PowerShell after install / exit code 3010).
CUDA must already be present from §0.2. See §3 and §4 for switches.

`-SkipVideo` exists only to isolate a build problem: it skips the video stage (engine without
video input). Normal installs run the un-skipped command above.

### 0.5 Model, config, start

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
# default target: D:\llm\models\Qwen3.8-Flash-Next-FP4-Local  (override with -TargetDir)
```

Edit `.env`: `MODEL_DIR` must point to the directory containing `config.json`; keep
`TENSORFOLD_IGNORE_STREAM_BUDGET=1` to bypass the over-cautious CUDA stream budget precheck.
Then:

```powershell
.\start.ps1     # parameters are 1:1 with start.sh
.\stop.ps1
```

See §7 for the verification checklist. If the engine fails on memory after all this, re-check
§0.1 — it is almost always the pagefile, not the physical RAM size.

## 1. What the repository provides, what the build produces

The repository provides source, scripts, patches and documentation. The engine checkout and all
binaries are produced locally by `build.ps1`, from pinned sources with SHA-256 verification
where available:

| Path | Origin |
|---|---|
| `start.ps1`, `stop.ps1`, `scripts/*.ps1`, `scripts/*.sh`, `scripts/*.py` | repository source |
| `patches/*.patch`, `patches/windows/*.patch` | repository source |
| `LICENSE`, `NOTICE`, `CREDITS.md`, `README.md`, `README.upstream.md`, `docs/`, `.env` | repository source |
| `build.ps1`, `build_skill.md`, `download-model.ps1` guidance | repository source |
| `tensorfold/` (engine checkout + `dist/`) | `build.ps1` stages `source` + `engine` |
| `third_party/optional-libs/*.dll` | stage `runtime` (downloaded from upstream releases) |
| `third_party/ffmpeg-dlls/`, `third_party/ffmpeg-prefix/` | stage `video` (PyAV wheel DLLs + source headers + zig dlltool import libs) |
| `.work/`, caches, `*.pdb` | transient; cleaned after build |

## 2. Dependency chain and correct stage order

```
source (TensorFold @93a2e93)
   └─> patches (LF-normalized Windows patch set)
         └─> runtime (non-GPL DLLs: turbojpeg/webp/pdfium/tfgrammar)
               └─> video (FFmpeg 9.0.2 ARM64 DLLs + headers + import libs -> tfvideo.dll)
                     └─> engine (zig native install + install all DLLs into dist)
                           └─> verify
```

Order matters: `scripts/build.ps1` (engine) calls `scripts/build-video.ps1` at its end, which
links `tfvideo.dll` against the **import libs produced by the video stage**. So `video` must run
before `engine`. The root `build.ps1` already encodes this order; never reorder manually.

## 3. Toolchain detection and setup (build.ps1 preflight)

`build.ps1 -PreflightOnly` detects everything and performs **no** download or install — use it
as the safe first check. The full `build.ps1` self-heals two tools and prompts for the third:

| Tool | Version | Missing behaviour | Default path |
|---|---|---|---|
| Zig | 0.17.0 aarch64-windows | **auto-download + extract** from `https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip` | `D:\building\zig-aarch64-windows-0.17.0\zig.exe` |
| VS2022 Build Tools native ARM64 | 17.x v143 `VC.Tools.ARM64` | **silent CLI install** via `vs_buildtools.exe` (needs elevated shell) | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` |
| CUDA Toolkit | 13.4 `nvcc.exe` | **prompt only — NEVER auto-installed**; operator installs the ARM64 GA build | `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4\bin\nvcc.exe` |
| git, python, curl, tar | any recent | prompt (must be on `PATH`) | — |

Exact VS Build Tools install command used by preflight (when elevated and `-NoAutoSetup` is not set):

```cmd
vs_buildtools.exe --quiet --wait --norestart ^
  --add Microsoft.VisualStudio.Workload.VCTools ^
  --add Microsoft.VisualStudio.Component.VC.Tools.ARM64
:: bootstrapper: https://aka.ms/vs/17/release/vs_buildtools.exe
:: exit code 3010 (reboot required) is accepted; reopen PowerShell after install
```

`-NoAutoSetup` force-disables all download/install even in a full build (detect and fail only).
CUDA is never auto-installed because toolkit selection/architecture must be the operator's choice;
the script prints the exact native-ARM64 GA archive:
`https://developer.nvidia.com/cuda-13-4-3-download-archive?target_os=Windows&target_arch=arm64&target_version=11&target_type=exe_local`.
MSVC target compilers are detected under `VC\Tools\MSVC\<ver>\bin\Hostx64\arm64\cl.exe` (or
`Hostarm64\arm64\`), not `bin\arm64\`.

The video stage needs no extra toolchain either: the FFmpeg DLLs are taken from the pinned PyAV
wheel, the headers from the official FFmpeg source tarball, and the import libraries are
generated with `zig dlltool` — all driven by `scripts/build-gpl-video.ps1`. `-SkipVideo` exists
only to isolate a build problem (engine without video input).

## 4. One-command build and useful variants

```powershell
# From the repository root, in an ARM64 PowerShell:
powershell -ExecutionPolicy Bypass -File .\build.ps1 -PreflightOnly   # 1. detect only (no install)
powershell -ExecutionPolicy Bypass -File .\build.ps1                   # 2. full build (self-heals Zig/VSBT)
powershell -ExecutionPolicy Bypass -File .\build.ps1 -NoAutoSetup      # detect + fail, never install
powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipVideo        # DIAGNOSTIC ONLY: engine + runtime, no video
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Stage runtime -ForceRuntime  # re-fetch DLLs
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Stage verify      # re-check a built tree
```

Key parameters: `-ZigExe`, `-Nvcc`, `-VsBuildTools`,
`-Jobs N` (default = core count), `-NoClean` (keep `.zig-cache` for debugging),
`-SkipPatches`, `-SkipRuntime`, `-ForceRuntime`.

Result: `tensorfold\dist\native\bin\tensorfold-native.exe` plus DLLs in
`tensorfold\dist\native\lib`. Intermediate caches (`.zig-cache`, `zig-out`, `.work\cuda-cache`)
are removed after a successful build unless `-NoClean`.

## 5. Pinned sources (do not upgrade without testing)

| Component | Pin | Source |
|---|---|---|
| TensorFold | `93a2e93ecebff8aa52b88e58c5dd222516e69c5f` (v1.2.7) | `github.com/ashhart/TensorFold.git` |
| FFmpeg ARM64 DLLs (avcodec/avformat/avutil/swscale + companions) | PyAV 19.0.1 wheel | PyPI `av-19.0.1-cp312-abi3-win_arm64.whl` (SHA-256 in `scripts/build-gpl-video.ps1`) |
| FFmpeg headers | 9.0.2 source | `ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz` (SHA-256 pinned in script) |
| turbojpeg | libjpeg-turbo 3.1.1 win arm64 | GitHub release `libjpeg-turbo-3.1.1-vc-arm64.exe` |
| pdfium | `chromium/7725` win arm64 | github.com/bblanchon/pdfium-binaries |
| tfgrammar | xgrammar 0.2.8 win_arm64 | PyPI `xgrammar-0.2.8-*-win_arm64.whl` |
| libwebpdecoder / libsharpyuv | PyAV 19.0.1 win_arm64 | same `av-19.0.1` wheel as above |

The video stage is assembled natively by `scripts/build-gpl-video.ps1`: DLLs from the wheel,
headers from the source tarball, import libs via `zig dlltool`, `tfvideo.dll` via
`zig build video`. The four non-GPL runtime DLLs are downloaded from their upstream release
archives and extracted in `build.ps1` stage `runtime`.

## 6. Model download (after the build)

The recipe expects a plain checkpoint directory (no HF cache, no symlinks), default
`D:\llm\models\Qwen3.8-Flash-Next-FP4-Local`. ModelScope's mirror of the NVIDIA checkpoint is
`nv-community/Qwen3.8-Flash-Next-FP4-Local` (the `nvidia/...` id is 404 on ModelScope). Use the
provided `scripts/download-model.ps1` (curl-only, resumable, flat layout):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -ListOnly   # preview 34 files / ~95 GiB
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1             # -> D:\llm\models\Qwen3.8-Flash-Next-FP4-Local
```

`scripts/config.ps1` already defaults `MODEL_DIR` to that path and prefers it when it contains
`config.json`. After download, start the service with `.\start.ps1` (parameters are 1:1 with
`start.sh`).

## 7. Verification checklist

- `build.ps1 -Stage verify` passes: engine PE machine `0xaa64` (ARM64), four runtime DLLs in
  `dist\native\lib`, `capabilities --json` reports `engine`/`version`/`chip`/`backends`.
- Optional library load: set `TENSORFOLD_LIBTURBOJPEG`, `TENSORFOLD_LIBWEBP`,
  `TENSORFOLD_LIBPDFIUM` to the absolute DLL paths in `.env`; `native\lib` is added to `PATH`.
- `TENSORFOLD_IGNORE_STREAM_BUDGET=1` disables the over-cautious CUDA stream memory precheck;
  real `cudaMalloc` failures remain fatal.
- `.ps1` files are UTF-8 **with BOM** (PowerShell 5.1); `.patch` and `.env` are UTF-8 **without
  BOM** and LF line endings. Do not convert patch files to CRLF.

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Preflight: Zig/nvcc/VS2022 missing | tool not installed or wrong path | install it, or pass `-ZigExe`/`-Nvcc`/`-VsBuildTools` |
| patch apply fails | CRLF/BOM in patch files | ensure `patches\windows\*.patch` are LF + no BOM |
| `zig build video` cannot find `avcodec.lib` | import libs not generated | re-run `video` stage; check `third_party\ffmpeg-prefix\lib` |
| `libsharpyuv.dll` not found at runtime | DLL not beside executable | re-run `runtime`; copy it to both `native\lib` and `native\bin` |
| engine refuses memory | stream budget precheck | set `TENSORFOLD_IGNORE_STREAM_BUDGET=1` in `.env` |
| host-memory / allocation OOM even with free RAM | WDDM pagefile too small | set 128 GiB custom pagefile per §0.1, then reboot |
| `MEMBER_NOT_FOUND` in runtime stage | upstream archive layout changed | inspect the archive, update the `Pattern` in `build.ps1` stage `runtime` |
| build too slow / oversubscribed | nvcc split compile + `-j20` | use `-Jobs 4` (split compile is opt-in in patch 0008) |

## 9. Licences of the components you build

- Repository contents: upstream MiaAI-Lab MIT + TensorFold Apache-2.0/MIT; keep `LICENSE`,
  `NOTICE`, `CREDITS.md` unchanged. Contributors may be added in `CREDITS.md`.
- The FFmpeg DLL set includes GPLv2+ components (x264/x265/vmaf); when redistributing anything
  linked against them, follow the GPL obligations (provide the corresponding sources).
- turbojpeg (BSD-3/IJG), libwebp/sharpyuv (BSD-3), PDFium (BSD-3 + sub-licences), xgrammar
  (Apache-2.0) are non-GPL; keep their licence texts with the DLLs you redistribute.
- Model weights are governed by the NVIDIA Open Model Agreement and the Qwen Community License 1.0.
