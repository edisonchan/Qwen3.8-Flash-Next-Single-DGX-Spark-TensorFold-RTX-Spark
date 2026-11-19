# Qwen3.8-Flash-Next NVFP4 — Windows 11 ARM64 Port

[中文](README.md) | English

Local inference recipe for **RTX Spark / DGX Spark (GB10, `sm_121`) on Windows 11 ARM64**, built and
run with a fully native Windows toolchain (Zig 0.17.0 + VS2022 Build Tools ARM64 + CUDA Toolkit 13.4),
no Docker / container dependency.

- Engine: TensorFold v1.2.7 (`93a2e93ecebff8aa52b88e58c5dd222516e69c5f`) Zig engine
- Default model: `nvidia/Qwen3.8-Flash-Next-FP4-Local` (ModelScope mirror: `nv-community/Qwen3.8-Flash-Next-FP4-Local`)
- API: OpenAI-compatible, default port `8888`, model ID `Qwen3.8-Flash-Next`
- Engine, dependency libraries and model are all produced locally by the build/download scripts in
  this repository; a fresh clone reproduces everything with one command

> The upstream DGX OS (DGX Spark) + Docker version is documented in the
> [MiaAI-Lab upstream README (README.upstream.md)](README.upstream.md).

## Acknowledgements

This recipe builds on the following upstream authors and projects:

| Project / Author | Contribution |
| --- | --- |
| [MiaAI-Lab (Mia's AI Lab)](https://github.com/MiaAI-Lab) | Original recipe, `start.sh`/`scripts/`, core patches, sparkDash test data; MIT |
| [Ash Hart & TensorFold contributors](https://github.com/ashhart/TensorFold) | TensorFold v1.2.7 Zig engine `tensorfold-native`, CUDA kernels and server; Apache-2.0 / early MIT |
| [Jürgen Schmied (jschmied)](https://github.com/jschmied) | Zig CUDA serving path and CUDA family registry from TensorFold PR #443 |
| [Qwen team (Alibaba)](https://huggingface.co/Qwen) | Qwen3.8 Flash Next model, chat template, MTP head; Qwen Community License 1.0 |
| [NVIDIA](https://huggingface.co/nvidia) | FP4 QAD checkpoint, RTX Spark / GB10 hardware and CUDA 13.4; NVIDIA Open Model Agreement |
| [chai-md](https://github.com/chai-md) | TensorFold video-input patch #90 (`patches/windows/0005` in this port) |
| [321sssrt-bit](https://github.com/321sssrt-bit) | Full-window admission fix and `tools/context_boundary.py` |
| [MLC-AI / xgrammar](https://github.com/mlc-ai/xgrammar), [libjpeg-turbo](https://libjpeg-turbo.org/), [libwebp](https://github.com/webmproject/libwebp), [PDFium/pypdfium2](https://pypdfium2.readthedocs.io/), [FFmpeg](https://ffmpeg.org/), [PyAV](https://github.com/PyAV-Org/PyAV), [Zig](https://ziglang.org) | Structured output, image/PDF/video decoding, compiler and other runtime dependencies |
| [sparkDash](https://github.com/MiaAI-Lab/sparkDash) | Benchmarking tool for the performance data |
| edisonchan | Windows 11 ARM64 port: `.ps1` scripts, Windows patches, DLL integration, build orchestration and this document |

Full attributions in [`CREDITS.md`](CREDITS.md); third-party notices in [`NOTICE`](NOTICE).

## Install & Use (fresh RTX Spark / Windows 11 ARM64)

### 1. Set 128 GB virtual memory first (WDDM)

Windows WDDM manages GPU-visible system memory through the page file. The model is ~95 GiB; a page
file that is too small causes "allocation failed even though memory looks free". Set this before
loading the model:

1. `Win + R` → `sysdm.cpl` → **Advanced** → **Performance: Settings** → **Advanced** → **Virtual memory: Change**
2. Uncheck "Automatically manage paging file size for all drives"
3. Select the **fastest NVMe** drive → "Custom size"
4. Set both initial and maximum size to **131072 MB (128 GiB)**; enter `128` if the dialog shows GiB
5. Click OK and **reboot**

Verify: `Get-CimInstance Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize`.
Keep at least **300 GB** free on that drive (128 GiB page file + ~95 GiB model + build scratch space).

### 2. Driver and CUDA 13.4 (install it yourself)

1. Install the current NVIDIA driver for RTX Spark, reboot, and confirm `nvidia-smi` sees the GPU.
2. Install the **native ARM64** CUDA Toolkit 13.4 (not the x64 / Linux packages), using the
   **GA release 13.4.3**, not the 13.4.0 Developer Preview:

   ```
   https://developer.nvidia.com/cuda-13-4-3-download-archive?target_os=Windows&target_arch=arm64&target_version=11&target_type=exe_local
   ```

   The installer is `cuda_13.4.3_windows_arm64.exe` (~3.5 GB). Reboot after installing, then run
   `nvcc --version` in a new PowerShell.

`build.ps1` **does not install CUDA automatically**; if it is missing the script prints the URL above
and stops.

### 3. Basic tools, clone the repository

Install native ARM64 `git` / `python` / `curl` on `PATH` (avoid the x86 emulation layer). Then:

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark.git
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

A fresh clone contains scripts and documents only; `tensorfold/`, `dist/` and all DLLs are generated
locally by the build step below.

### 4. Build (native toolchain, one command)

```powershell
# (1) detection only — no downloads, no installs
powershell -ExecutionPolicy Bypass -File .\build.ps1 -PreflightOnly

# (2) full build: source → patches → runtime libs → video libs → engine → verify
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

Fully native Windows ARM64: **Zig 0.17.0 + VS2022 Build Tools ARM64 + CUDA 13.4 nvcc** — no MSYS2,
no conda, no cross toolchain.

- If Zig 0.17.0 is missing, the script downloads and unpacks it automatically.
- If VS2022 Build Tools ARM64 is missing, the script installs it with the official silent command
  (requires administrator; after exit code 3010, open a new shell).
- CUDA 13.4 must be installed first per step 2; the script only points to it, never installs it.
- Video stage: extracts the FFmpeg 9.0.2 ARM64 DLLs from the pinned PyAV wheel, extracts headers from
  the official FFmpeg source tarball, generates import libraries with `zig dlltool`, then compiles
  `tfvideo.dll` natively via `zig build video`.

> `-SkipVideo` exists only to isolate build problems: it skips the video stage (the engine loses video
> input, everything else is unaffected). For normal builds run the full command above.

Outputs: `tensorfold\dist\native\bin\tensorfold-native.exe`, DLLs under `tensorfold\dist\native\lib`.
Build caches are cleaned automatically on success (`-NoClean` keeps them for debugging).

### 5. Download the model

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
# default location: D:\llm\models\Qwen3.8-Flash-Next-FP4-Local, use -TargetDir for another directory
```

Zero-dependency curl download, laid out flat under `D:\llm\models\Qwen3.8-Flash-Next-FP4-Local` —
**no cache, no symlinks, no `.git`** — with resumable downloads.
Manifest: 34 files, ~95.2 GiB, including `config.json`, `tensors/model-00001..00021` and the tokenizer.

### 6. Configure and start

Edit `.env`:

```dotenv
MODEL_DIR=D:\llm\models\Qwen3.8-Flash-Next-FP4-Local
TENSORFOLD_IGNORE_STREAM_BUDGET=1
```

`TENSORFOLD_IGNORE_STREAM_BUDGET=1` bypasses the over-cautious CUDA stream budget precheck; a real
`cudaMalloc` failure is still fatal.
To use the optional DLLs, also set absolute paths for `TENSORFOLD_LIBTURBOJPEG` / `TENSORFOLD_LIBWEBP` /
`TENSORFOLD_LIBPDFIUM`.

```powershell
.\start.ps1
.\stop.ps1
```

The `.ps1` parameters map **1:1** to the upstream `.sh` scripts. After startup, verify:

```powershell
curl http://127.0.0.1:8888/v1/models
curl http://127.0.0.1:8888/health
curl http://127.0.0.1:8888/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 1000
}'
```

### 7. LAN access (optional)

The server binds `0.0.0.0:8888` by default, i.e. it listens on all interfaces; `HOST` / `PORT` can be
overridden in `.env` (setting `HOST` to `127.0.0.1` restricts it to loopback, making LAN access
impossible). Whether other machines can connect depends only on the firewall — Windows drops inbound
connections that are not allowed by a rule.

Open TCP 8888 in an **administrator** PowerShell:

```powershell
netsh advfirewall firewall add rule name="TensorFold (8888)" dir=in action=allow protocol=TCP localport=8888 profile=any
```

Equivalent cmdlet:

```powershell
New-NetFirewallRule -DisplayName "TensorFold (8888)" -Direction Inbound -Protocol TCP -LocalPort 8888 -Action Allow -Profile Any
```

> **`profile=any` is required.** Newly connected networks default to "Public" on Windows, and a rule
> written for `private,domain` never matches on public networks — the symptom is "works locally, other
> machines can't connect". `profile=any` still opens only this one port. Do not switch the whole
> adapter to "Private network" just to make it work: that would also expose file sharing, printing,
> device discovery and more.

Verify the rule:

```powershell
Get-NetFirewallRule -DisplayName "TensorFold*" | Select-Object DisplayName, Enabled, Direction, Action, Profile
```

> On localized Windows, `netsh` output is GBK-encoded, so `findstr` / `Select-String` on keywords like
> "Enabled" often returns nothing in PowerShell 7 and looks like the rule is missing — trust the cmdlet
> above, or the full output of `netsh advfirewall firewall show rule name="TensorFold (8888)"`.

Test from another machine:

```powershell
$ip = '192.168.1.100'                  # example address — replace with this machine's LAN IP
Test-NetConnection $ip -Port 8888      # expect TcpTestSucceeded : True
curl.exe "http://${ip}:8888/v1/models"
```

Find the local IP:

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object IPAddress, InterfaceAlias
```

In the (OpenAI-compatible) client set Base URL `http://<LAN-IP>:8888/v1` and model
`Qwen3.8-Flash-Next`; the server does not check an API key — any value or none works.

If it doesn't connect, check in order:

1. `Test-NetConnection` times out → `ping <LAN-IP>` first; failure means the two machines are on
   different subnets.
2. The router / AP has **client isolation (AP Isolation)** enabled, or the client is on a **guest
   network** — both make same-subnet devices invisible to each other.
3. Changed the port → update `localport` in the firewall rule accordingly.
4. Only localhost works → go back to the `profile=any` check above.

> The readiness probes in `start.ps1` / `stop.ps1` always use `127.0.0.1`, independent of the external
> bind address; they do not affect LAN access.

> The server has no built-in auth or TLS. Deploy it only on a trusted LAN; do not map it to the public
> internet. To expose it, put a reverse proxy in front with authentication and HTTPS.

### 8. Optional: video / PDF / image

- `VIDEO=1`: requires the full build from step 4 (video libraries are generated natively by
  `build.ps1`) and `native\lib` on `PATH`.
- `PDF=1`: renders PDF pages to images via `pdfium.dll`.
- Images: JPEG / PNG / WebP decoded by `turbojpeg.dll` and `libwebpdecoder.dll`.
- Video / PDF paths on this Windows port have **no end-to-end live validation yet**; the text path does
  not touch them.

## Repository layout

```text
README.md              Chinese entry: Windows quickstart, install/use, test data
README.en.md           This file (English)
README.upstream.md     MiaAI-Lab upstream (DGX OS / Docker) README
build.ps1              One-command build entry (source→patches→runtime→video→engine→verify)
build_skill.md         Build guide: toolchain, pinned versions, per-stage commands, troubleshooting
start.ps1 / stop.ps1   Start/stop the server, parameters identical to start.sh / stop.sh
scripts/               config.ps1, banner.ps1, build.ps1, build-video.ps1,
                       build-gpl-video.ps1, download-model.ps1, apply-patches.ps1, ...
patches/               Upstream patches (0001..0005)
patches/windows/       Windows adaptation patches (0001..0008)
tools/                 Checks and benchmark scripts
docs/                  Supplementary docs; docs/images/ holds sparkDash benchmark screenshots
LICENSE / NOTICE / CREDITS.md   Licenses and attributions
```

`tensorfold/`, `third_party/`, `dist/` are build artifacts generated locally by `build.ps1`.

## Test data

### A. Build and runtime checks (this machine, Windows 11 ARM64)

| Item | Result |
| --- | --- |
| Platform | Windows 11 ARM64, RTX Spark / GB10, `sm_121` |
| Toolchain | Zig 0.17.0; VS2022 BuildTools ARM64 (MSVC 14.44.35207); CUDA 13.4 nvcc |
| Patches | `patches/windows/0001..0008` apply cleanly in order from a fresh TensorFold worktree |
| Full build | ~10.5 min on 20 threads; `tensorfold-native.exe` 49,364,224 bytes; PE machine `0xaa64` (ARM64) |
| `capabilities --json` | `engine=zig`, `version=1.2.7`, `chip=nvidia-sm121`, `backends=cuda` |
| Optional libs | turbojpeg / libwebp / pdfium / tfgrammar all `found=true`; turbojpeg / libwebp `usable=true` |
| Model manifest | `-ListOnly`: 34 files / 95.2 GiB, `config.json` + `tensors/model-00001..00021` + tokenizer |
| Post-build cleanup | No `.zig-cache`, `zig-out`, `.work`, `__pycache__` left behind |
| Preflight | `build.ps1 -PreflightOnly` reports all toolchain checks `[ OK ]`, no downloads/installs |
| LAN access | After allowing inbound TCP 8888 (`profile=any`), a LAN client connects; server `GET /health` returns `200` |

### B. Performance: sparkDash (this machine, Windows 11 ARM64)

Host: **ASUS ProArt GR1X (RTX Spark SFF, 128 GB RAM / 2 TB SSD)**, Windows 11 ARM64, NVIDIA GB10
(`sm_121`); model `Qwen3.8-Flash-Next` (NVFP4), TensorFold v1.2.7 native build, port 8888;
benchmarked with [sparkDash](https://github.com/MiaAI-Lab/sparkDash) in `Open · Local` mode, 2026-11-19.

**Decode configurations** (all: 400-token output, top_k 20, 1–5 concurrent streams)

| Configuration | Single-stream tok/s | ×5 aggregate tok/s | ×5 TTFT |
| --- | ---: | ---: | ---: |
| Prose, thinking off, temp 0 | 68.2 | 162.9 | 358 ms |
| Prose, thinking on, temp 0.7 | 58.2 | 120.0 | 473 ms |
| Code, thinking off, temp 0 | 98.6 | 211.1 | 417 ms |

#### B.1 Decode · Prose (400 tokens, temp 0, thinking off, top_k 20)

![sparkDash decode benchmark: Prose, thinking off](docs/images/sparkdash-decode-prose.png)

| Concurrency | TTFT | Aggregate tok/s | Per-stream tok/s |
| ---: | ---: | ---: | ---: |
| ×1 | 107 ms | 68.2 | 68.2 |
| ×2 | 179 ms | 90.0 | 46.7 |
| ×3 | 234 ms | 117.2 | 40.4 |
| ×4 | 294 ms | 137.0 | 35.6 |
| ×5 | 358 ms | 162.9 | 34.1 |

#### B.2 Decode · Prose + thinking (400 tokens, temp 0.7, thinking on, top_k 20)

![sparkDash decode benchmark: Prose, thinking on](docs/images/sparkdash-decode-thinking.png)

| Concurrency | TTFT | Aggregate tok/s | Per-stream tok/s |
| ---: | ---: | ---: | ---: |
| ×1 | 150 ms | 58.2 | 58.2 |
| ×2 | 228 ms | 78.0 | 40.0 |
| ×3 | 301 ms | 101.3 | 35.6 |
| ×4 | 383 ms | 108.9 | 29.8 |
| ×5 | 473 ms | 120.0 | 26.8 |

#### B.3 Decode · Code (400 tokens, temp 0, thinking off, top_k 20)

![sparkDash decode benchmark: Code, thinking off](docs/images/sparkdash-decode-code.png)

| Concurrency | TTFT | Aggregate tok/s | Per-stream tok/s |
| ---: | ---: | ---: | ---: |
| ×1 | 138 ms | 98.6 | 98.6 |
| ×2 | 203 ms | 140.4 | 73.3 |
| ×3 | 276 ms | 173.4 | 61.1 |
| ×4 | 353 ms | 194.1 | 51.6 |
| ×5 | 417 ms | 211.1 | 45.2 |

#### B.4 Prefill (cold, 1k → 128k context)

![sparkDash prefill benchmark](docs/images/sparkdash-prefill.png)

| Context | Actual tokens | TTFT | Prefill tok/s |
| ---: | ---: | ---: | ---: |
| 1k | 1,064 | 442 ms | 3,448.8 ¹ |
| 2k | 2,089 | 787 ms | 3,197.5 |
| 4k | 4,137 | 1.53 s | 2,953.1 |
| 8k | 8,232 | 3.02 s | 2,856.2 |
| 16k | 16,423 | 6.05 s | 2,778.1 |
| 32k | 32,808 | 12.25 s | 2,707.4 |
| 64k | 65,575 | 25.10 s | 2,626.7 |
| 128k | 131,113 | 52.49 s | 2,504.1 |

¹ sparkDash flags this point as low-confidence: only 1,064 tokens, request overhead dominates.

**Reading notes**

- Single-stream decode: Prose 68.2 / Code 98.6 tok/s; at 5 concurrent streams the aggregate reaches
  162.9 / 211.1 tok/s (≈2.4× / 2.1×), with per-stream dropping to 34.1 / 45.2 accordingly.
- With thinking on (temp 0.7): single-stream 58.2 tok/s, 5-stream aggregate 120.0; at equal concurrency
  TTFT rises from 107 ms to 150 ms (358 → 473 ms at ×5).
- Prefill decays smoothly from 3,197.5 tok/s at 2k to 2,504.1 tok/s at 128k; first token at 128k
  context takes ~52.5 s. Cold start, no prefix-cache hits.
- Decode runs are short tests (fixed 400-token output, 35–61 s per run); they do **not** cover
  long-context combined with high concurrency, nor KV-cache reuse across multi-turn conversations.
  Video / PDF input paths have no end-to-end server test yet.

### C. Quality and tool evaluation: sparkDash (this machine, Windows 11 ARM64)

2026-11-20, run from the sparkDash dashboard pages `bench/quality` and `bench/tool-eval`
(`http://127.0.0.1:5555`).

| Suite | Result |
| --- | --- |
| Quality benchmark | **94.0 / 100** · 12 categories · 2,230 items · 334 m 56 s |
| Tool evaluation | **89.0 / 100** (`Adequate`, safety-capped) · deployability 76.0 · responsiveness 47.0 · 104 scenarios (88 pass / 9 partial / 7 fail) · 25 m 48 s |

![sparkDash quality benchmark](docs/images/sparkdash-quality.png)

![sparkDash tool evaluation](docs/images/sparkdash-tool-eval.png)

## License

- This repository follows the upstream MIT license (`LICENSE`, `NOTICE`, `CREDITS.md`).
- TensorFold engine: Apache-2.0 / early MIT; keep its LICENSE / NOTICE / THIRD_PARTY_NOTICES when
  redistributing build artifacts.
- Video stack FFmpeg / x264 / x265 / vmaf: GPLv2+, built locally from source by `build.ps1`; when
  redistributing artifacts linked against them, fulfill the GPL obligations (ship the corresponding
  sources).
- Non-GPL runtime libraries: turbojpeg (BSD-3/IJG), libwebp (BSD-3), PDFium (BSD-3 + sub-licenses),
  xgrammar (Apache-2.0), fetched from upstream by the build scripts.
- Model weights: NVIDIA Open Model Agreement and Qwen Community License 1.0.

Per-component licenses: see [`build_skill.md`](build_skill.md) §9 and [`NOTICE`](NOTICE).
