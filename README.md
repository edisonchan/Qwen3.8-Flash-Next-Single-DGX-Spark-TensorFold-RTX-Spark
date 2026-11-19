# Qwen3.8-Flash-Next NVFP4 — Windows 11 ARM64 移植版

面向 **RTX Spark / DGX Spark（GB10, `sm_121`）Windows 11 ARM64** 的本地推理配方，基于原生
Windows 工具链构建并运行（Zig 0.17.0 + VS2022 Build Tools ARM64 + CUDA Toolkit 13.4），无 Docker / 容器依赖。

- 引擎：TensorFold v1.2.7（`93a2e93ecebff8aa52b88e58c5dd222516e69c5f`）Zig 引擎
- 默认模型：`nvidia/Qwen3.8-Flash-Next-FP4-Local`（ModelScope 镜像：`nv-community/Qwen3.8-Flash-Next-FP4-Local`）
- API：OpenAI 兼容，默认端口 `8888`，模型 ID `Qwen3.8-Flash-Next`
- 引擎、依赖库与模型全部由仓库内的构建/下载脚本在本机生成，克隆后一条命令即可复现

> Linux / Docker 版本的完整说明见 [MiaAI-Lab 上游 README（README.upstream.md）](README.upstream.md)。

## 致谢

本配方建立在以下上游作者与项目之上：

| 项目 / 作者 | 贡献 |
| --- | --- |
| [MiaAI-Lab（Mia's AI Lab）](https://github.com/MiaAI-Lab) | 原配方、`start.sh`/`scripts/`、核心 patches、sparkDash 测试数据；MIT |
| [Ash Hart 与 TensorFold contributors](https://github.com/ashhart/TensorFold) | TensorFold v1.2.7 Zig 引擎 `tensorfold-native`、CUDA kernel 与服务；Apache-2.0 / 早期 MIT |
| [Jürgen Schmied（jschmied）](https://github.com/jschmied) | TensorFold PR #443 的 Zig CUDA serving path 与 CUDA family registry |
| [Qwen team（Alibaba）](https://huggingface.co/Qwen) | Qwen3.8 Flash Next 模型、chat template、MTP head；Qwen Community License 1.0 |
| [NVIDIA](https://huggingface.co/nvidia) | FP4 QAD checkpoint、RTX Spark / GB10 硬件与 CUDA 13.4；NVIDIA Open Model Agreement |
| [chai-md](https://github.com/chai-md) | TensorFold 视频输入 patch #90（本移植中为 `patches/windows/0005`） |
| [321sssrt-bit](https://github.com/321sssrt-bit) | 满窗口 admission 修复与 `tools/context_boundary.py` |
| [MLC-AI / xgrammar](https://github.com/mlc-ai/xgrammar)、[libjpeg-turbo](https://libjpeg-turbo.org/)、[libwebp](https://github.com/webmproject/libwebp)、[PDFium/pypdfium2](https://pypdfium2.readthedocs.io/)、[FFmpeg](https://ffmpeg.org/)、[PyAV](https://github.com/PyAV-Org/PyAV)、[Zig](https://ziglang.org) | 结构化输出、图像/PDF/视频解码、编译器等运行时依赖 |
| [sparkDash](https://github.com/MiaAI-Lab/sparkDash) | 上游性能数据的基准工具 |
| edisonchan | Windows 11 ARM64 移植：`.ps1` 脚本、Windows patches、DLL 集成、构建编排与本文档 |

完整署名见 [`CREDITS.md`](CREDITS.md)，第三方声明见 [`NOTICE`](NOTICE)。

## 安装与使用（全新 RTX Spark / Windows 11 ARM64）

### 1. 先设置 128 GB 虚拟内存（WDDM）

Windows 的 WDDM 通过页文件管理 GPU 可见的系统内存。模型约 95 GiB，页文件过小会导致「看似有空闲内存但仍分配失败」。
在加载模型前设置：

1. `Win + R` → `sysdm.cpl` → **高级** → **性能：设置** → **高级** → **虚拟内存：更改**
2. 取消「自动管理所有驱动器的分页文件大小」
3. 选择**最快的 NVMe** 盘 → 「自定义大小」
4. 初始大小和最大值都填 **131072 MB（128 GiB）**；若界面按 GiB 显示则填 `128`
5. 确定后**重启**

验证：`Get-CimInstance Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize`。
该盘至少保留 **300 GB** 空闲（页文件 128 GiB + 模型约 95 GiB + 构建临时空间）。

### 2. 驱动与 CUDA 13.4（用户本人安装）

1. 安装 RTX Spark 当前 NVIDIA 驱动，重启，`nvidia-smi` 能看到 GPU。
2. 安装**原生 ARM64** CUDA Toolkit 13.4（不要 x64 / Linux 包），使用 **GA 正式版 13.4.3**，不要用 13.4.0 Developer Preview：

   ```
   https://developer.nvidia.com/cuda-13-4-3-download-archive?target_os=Windows&target_arch=arm64&target_version=11&target_type=exe_local
   ```

   安装包为 `cuda_13.4.3_windows_arm64.exe`（约 3.5 GB），装完重启，新开 PowerShell 运行 `nvcc --version`。

`build.ps1` **不会自动安装 CUDA**；缺失时只打印上面的地址并停止。

### 3. 基础工具、克隆仓库

安装原生 ARM64 的 `git` / `python` / `curl` 并加入 `PATH`（避免 x86 模拟层）。然后：

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark.git
cd Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold-RTX-Spark
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

刚克隆的仓库只有脚本与文档；`tensorfold/`、`dist/` 和各种 DLL 都由下面的构建步骤在本机生成。

### 4. 构建（原生工具链，一条命令）

```powershell
# ① 只检测，不下载、不安装
powershell -ExecutionPolicy Bypass -File .\build.ps1 -PreflightOnly

# ② 完整构建：源码 → 补丁 → 运行时库 → 视频库 → 引擎 → 验证
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

全程原生 Windows ARM64：**Zig 0.17.0 + VS2022 Build Tools ARM64 + CUDA 13.4 nvcc**，不需要 MSYS2、conda 或任何交叉工具链。

- Zig 0.17.0 缺失时脚本自动下载并解压。
- VS2022 Build Tools ARM64 缺失时脚本用官方静默命令安装（需管理员权限，装完退出码 3010 后重开 shell）。
- CUDA 13.4 需按第 2 步先装好；脚本只提示，不安装。
- 视频库阶段：从 pin 定的 PyAV wheel 提取 FFmpeg 9.0.2 ARM64 DLL、从 FFmpeg 官方源码包提取头文件、用 `zig dlltool` 生成导入库，再由 `zig build video` 原生编译 `tfvideo.dll`。

> `-SkipVideo` 仅用于隔离构建问题，会跳过视频阶段（引擎无视频输入，其余不受影响）；日常构建直接运行上面的完整命令。

产物：`tensorfold\dist\native\bin\tensorfold-native.exe`，DLL 在 `tensorfold\dist\native\lib`。
构建中间缓存会在成功后自动清理（`-NoClean` 可保留用于排错）。

### 5. 下载模型

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\scripts\download-model.ps1
# 默认落盘位置：D:\llm\models\Qwen3.8-Flash-Next-FP4-Local，可用 -TargetDir 指定其他目录
```

零依赖 curl 下载，直接平铺落盘到 `D:\llm\models\Qwen3.8-Flash-Next-FP4-Local`，**无 cache、无软链、无 `.git`**，支持断点续传。
清单：34 个文件、约 95.2 GiB，含 `config.json`、`tensors/model-00001..00021` 与 tokenizer。

### 6. 配置与启动

编辑 `.env`：

```dotenv
MODEL_DIR=D:\llm\models\Qwen3.8-Flash-Next-FP4-Local
TENSORFOLD_IGNORE_STREAM_BUDGET=1
```

`TENSORFOLD_IGNORE_STREAM_BUDGET=1` 用于忽略过度恐慌的 CUDA stream 预算预检；真实 `cudaMalloc` 失败仍为致命错误。
若使用可选 DLL，再设置 `TENSORFOLD_LIBTURBOJPEG` / `TENSORFOLD_LIBWEBP` / `TENSORFOLD_LIBPDFIUM` 的绝对路径。

```powershell
.\start.ps1
.\stop.ps1
```

`.ps1` 参数与上游 `.sh` **1:1 对应**。启动后验证：

```powershell
curl http://127.0.0.1:8888/v1/models
curl http://127.0.0.1:8888/health
curl http://127.0.0.1:8888/v1/chat/completions -H "Content-Type: application/json" -d '{
  "model": "Qwen3.8-Flash-Next",
  "messages": [{"role": "user", "content": "Write a Python fibonacci function."}],
  "max_tokens": 1000
}'
```

### 7. 局域网访问（可选）

服务默认绑定 `0.0.0.0:8888`，即在所有网卡上监听；`HOST` / `PORT` 可在 `.env` 中覆盖（若把 `HOST` 设为 `127.0.0.1`，则只监听回环，局域网无法访问）。其他机器能否连上只取决于防火墙——Windows 默认丢弃未放行的入站连接。

用**管理员** PowerShell 放行 TCP 8888：

```powershell
netsh advfirewall firewall add rule name="TensorFold (8888)" dir=in action=allow protocol=TCP localport=8888 profile=any
```

等价的 cmdlet 写法：

```powershell
New-NetFirewallRule -DisplayName "TensorFold (8888)" -Direction Inbound -Protocol TCP -LocalPort 8888 -Action Allow -Profile Any
```

> **`profile=any` 是必须的。** 新接入的网络在 Windows 上默认被判为「公用网络」，只写了 `private,domain` 的规则在公用网络下根本不匹配，症状是「本机能访问、别的机器连不上」。`profile=any` 仍然只放行这一个端口；不建议为了让网络通把整块网卡改成「专用网络」，那会一并放开文件共享、打印机、设备发现等一批服务。

验证规则：

```powershell
Get-NetFirewallRule -DisplayName "TensorFold*" | Select-Object DisplayName, Enabled, Direction, Action, Profile
```

> 中文系统上 `netsh` 的输出是 GBK 编码，在 PowerShell 7 里用 `findstr` / `Select-String` 匹配「已启用」「配置文件」这类中文关键字常常返回空，看着像规则没建——以上面的 cmdlet，或 `netsh advfirewall firewall show rule name="TensorFold (8888)"` 的完整输出为准。

从另一台机器测试：

```powershell
$ip = '192.168.1.100'                  # 示例地址，替换为本机局域网 IP
Test-NetConnection $ip -Port 8888      # 期望 TcpTestSucceeded : True
curl.exe "http://${ip}:8888/v1/models"
```

本机 IP 获取：

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
  Select-Object IPAddress, InterfaceAlias
```

客户端（OpenAI 兼容）填：Base URL `http://<本机局域网IP>:8888/v1`，模型 `Qwen3.8-Flash-Next`；服务不校验 API Key，任意值或留空均可。

连不上时按顺序排查：

1. `Test-NetConnection` 超时 → 先 `ping <本机局域网IP>`；不通说明两台机器不在同一网段。
2. 路由器 / AP 开了**客户端隔离（AP Isolation）**，或客户端连的是**访客网络**——两者都会让同网段设备互不可见。
3. 改过端口 → 防火墙规则里的 `localport` 要同步修改。
4. 只有本机能通 → 回到上面的 `profile=any` 检查规则生效范围。

> `start.ps1` / `stop.ps1` 的就绪探测固定走 `127.0.0.1`，与对外监听地址无关，不影响局域网访问。

> 服务不内置鉴权与 TLS，只应部署在可信局域网内，不要直接映射到公网。需要对外提供时，请在前置反向代理上做认证与 HTTPS。

### 8. 可选：视频 / PDF / 图像

- `VIDEO=1`：需要第 4 步的完整构建（视频库由 `build.ps1` 原生生成），并把 `native\lib` 加入 `PATH`。
- `PDF=1`：使用 `pdfium.dll` 渲染 PDF 页面为图像。
- 图像：JPEG / PNG / WebP 由 `turbojpeg.dll`、`libwebpdecoder.dll` 解码。
- 视频/PDF 在 Windows 移植上**尚未做端到端实跑验证**；文本路径不经过它们。

## 仓库结构

```text
README.md              本文件：Windows 上手、安装使用、测试数据
README.upstream.md     MiaAI-Lab 上游（Linux/Docker 版）README
build.ps1              一键构建入口（source→patches→runtime→video→engine→verify）
build_skill.md         构建指南：工具链、pin 版本、分阶段命令、排错
start.ps1 / stop.ps1   启动/停止服务，参数与 start.sh / stop.sh 一致
scripts/               config.ps1、banner.ps1、build.ps1、build-video.ps1、
                       build-gpl-video.ps1、download-model.ps1、apply-patches.ps1 等
patches/               上游 patches（0001..0005）
patches/windows/       Windows 适配 patches（0001..0008）
tools/                 检查与基准脚本
LICENSE / NOTICE / CREDITS.md   许可证与署名
```

`tensorfold/`、`third_party/`、`dist/` 为构建产物，由 `build.ps1` 在本地生成。

## 测试数据

### A. 本 Windows 11 ARM64 移植的实测

| 项目 | 结果 |
| --- | --- |
| 平台 | Windows 11 ARM64，RTX Spark / GB10，`sm_121` |
| 工具链 | Zig 0.17.0；VS2022 BuildTools ARM64（MSVC 14.44.35207）；CUDA 13.4 nvcc |
| 补丁 | `patches/windows/0001..0008` 从干净 TensorFold worktree 顺序应用通过 |
| 完整构建 | 20 线程约 10.5 分钟；产物 `tensorfold-native.exe` 49,364,224 字节；PE machine `0xaa64`（ARM64） |
| `capabilities --json` | `engine=zig`，`version=1.2.7`，`chip=nvidia-sm121`，`backends=cuda` |
| 可选库 | turbojpeg / libwebp / pdfium / tfgrammar 均 `found=true`；turbojpeg / libwebp `usable=true` |
| 模型清单 | `-ListOnly`：34 文件 / 95.2 GiB，`config.json` + `tensors/model-00001..00021` + tokenizer |
| 构建后清理 | 无 `.zig-cache`、`zig-out`、`.work`、`__pycache__` 残留 |
| 安全检测 | `build.ps1 -PreflightOnly` 工具链检测全 `[ OK ]`，未触发任何下载/安装 |
| 局域网访问 | 放行 TCP 8888 入站（`profile=any`）后，局域网客户端连通成功；服务端 `GET /health` 返回 `200` |

**未实测**：没有在本机重新下载并加载约 96 GiB 权重做吞吐测试，tok/s、TTFT、prefill 数值以上游数据为参考；视频/PDF 路径没有端到端服务测试。

### B. 上游 DGX Spark（Linux）数据 — 引自 [`README.upstream.md`](README.upstream.md)，非本机实测

v1.1.4 与 v1.2.7 A/B（`tools/bench_streams.py`，同一 Spark，默认参数，greedy，256 tokens，3 次中位数）：

| 指标 | v1.1.4 | v1.2.7 | 变化 |
| --- | ---: | ---: | ---: |
| Decode prose 1/3/5 streams（总 tok/s） | 57.8 / 133.4 / 167.9 | 58.5 / 156.1 / 230.1 | +1% / +17% / +37% |
| Decode code 1/3/5 streams（总 tok/s） | 48.2 / 104.0 / 141.3 | 51.9 / 138.8 / 206.8 | +8% / +33% / +46% |
| TTFT 5 streams prose/code（ms） | 440 / 372 | 177 / 173 | -60% / -53% |
| Prefill 4k/31k/126k（tok/s） | 2,329 / 2,566 / 2,397 | 2,108 / 2,166 / 2,047 | -9% / -16% / -15% |

v1.1.4 sparkDash 数据（默认 checkpoint、262,144 窗口、5 并发、fp8 KV、vision on）：

| 并发 | Decode prose 聚合 | Decode code 聚合 |
| ---: | ---: | ---: |
| 1 | 55.6 tok/s | 110.5 tok/s |
| 2 | 95.4 tok/s | 147.2 tok/s |
| 4 | 145.1 tok/s | 192.9 tok/s |
| 5 | 156.1 tok/s | 217.6 tok/s |

Prefill（cold）：4,134 tokens → 3,050 tok/s；32,807 → 2,735 tok/s；131,110 → 2,269 tok/s。
更多检查项（exact/toolcheck/visioncheck/prompt_reuse/context_boundary）见 `README.upstream.md` 的 **Checks** 章节。

## 许可

- 本仓库遵循上游 MIT 协议（`LICENSE`、`NOTICE`、`CREDITS.md`）。
- TensorFold 引擎：Apache-2.0 / 早期 MIT；再分发构建产物时请一并保留其 LICENSE / NOTICE / THIRD_PARTY_NOTICES。
- 视频栈 FFmpeg / x264 / x265 / vmaf：GPLv2+，由 `build.ps1` 在本地从源码构建；再分发链接了它们的产物时须履行 GPL 义务（随附对应源码）。
- 非 GPL 运行时库：turbojpeg（BSD-3/IJG）、libwebp（BSD-3）、PDFium（BSD-3 + 子许可）、xgrammar（Apache-2.0），构建时由脚本从上游获取。
- 模型权重遵循 NVIDIA Open Model Agreement 与 Qwen Community License 1.0。

各组件许可详见 [`build_skill.md`](build_skill.md) §9 与 [`NOTICE`](NOTICE)。
