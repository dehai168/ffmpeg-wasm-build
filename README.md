# ffmpeg-wasm-build

将 FFmpeg 编译为 **WebAssembly (WASM)**，供 H5 播放器在浏览器端直接调用，默认仅保留 **H.264 / H.265 / AAC / Opus** 解码与常见容器解封装能力，以尽量缩小 `.wasm` 体积并缩短编译时间。

---

## 特性

| 功能 | 说明 |
|---|---|
| H.264 解码 | 内置软件解码器，无需外部库 |
| H.264 编码 | 默认关闭；如确需转码可手动启用 libx264 |
| H.265/HEVC 解码 | 内置软件解码器，无需外部库 |
| H.265/HEVC 编码 | 默认关闭；如确需转码可手动启用 libx265 |
| 浏览器兼容 | x86 Chrome / Firefox / Safari / Edge |
| 模块化输出 | `createFFmpegCore()` 工厂函数，支持 Web Worker |
| 可配置编译参数 | 所有关键参数集中在 `build.config.sh` 中 |

---

## 项目结构

```
ffmpeg-wasm-build/
├── .devcontainer/
│   └── devcontainer.json    # GitHub Codespace 开发环境配置
├── .github/
│   └── workflows/
│       └── build.yml        # GitHub Actions 手动触发编译 + 自动 Release
├── scripts/
│   ├── build-deps.sh        # 按需编译 libx264 / libx265（WASM 静态库）
│   └── build-ffmpeg.sh      # 下载、配置、编译 FFmpeg，链接生成 WASM
├── build.config.sh          # ⭐ 编译参数配置文件（按需修改此文件）
├── build.sh                 # 主编译入口
└── README.md
```

---

## 快速开始

### 方式一：GitHub Actions（推荐）

无需本地环境，直接在 GitHub 上触发编译：

1. 进入仓库页面 → **Actions** → **Build FFmpeg WASM**
2. 点击 **Run workflow**
3. 填写 Release 标签（如 `v1.0.0`）和名称
4. 点击 **Run workflow** 开始编译
5. 编译成功后，在 **Releases** 页面下载 `ffmpeg-core.js` 和 `ffmpeg-core.wasm`

### 方式二：GitHub Codespace（在线开发环境）

1. 点击仓库页面的 **Code** → **Codespaces** → **Create codespace on main**
2. 等待 Codespace 启动（自动安装 Emscripten 等工具）
3. 在终端中运行：
   ```bash
   ./build.sh
   ```
4. 产物位于 `output/` 目录

### 方式三：本地编译

**前置条件：**
- [Emscripten SDK](https://emscripten.org/docs/getting_started/downloads.html)（版本见 `build.config.sh` 中的 `EMSDK_VERSION`）
- `nasm`, `cmake`, `ninja`, `python3`, `git`, `curl`

```bash
# 激活 Emscripten 环境
source /path/to/emsdk/emsdk_env.sh

# （可选）修改编译配置
vi build.config.sh

# 开始编译（默认解码版通常明显快于完整编解码版）
./build.sh

# 清理后重新编译
./build.sh --clean
```

---

## 与 iov-h5player 集成

本仓库会额外编译 `iov/iov_decoder.c`，并在 `ffmpeg-core.js` 上挂载 `Module.iovDecoder`，供 `iov-h5player` 的 `ffmpeg-decoder.worker.js` 做 **FLV tag 级软解码**（H.264/H.265 + AAC/MP3/Opus）。

```bash
cp output/ffmpeg-core.js output/ffmpeg-core.wasm ../iov-h5player/public/assets/ffmpeg/
```

解码输出优先为 **I420 YUV 平面帧**，由播放器 WebGL 渲染，适合移动端浏览器和微信小程序 WebView 等无 MSE 场景。页面需配置 COOP/COEP 以启用 pthreads + SharedArrayBuffer。

---

## 编译配置

所有可调参数均位于 **`build.config.sh`**，每个参数都有详细注释。

### 常用配置项速览

```bash
# 版本
FFMPEG_VERSION="6.1.1"      # FFmpeg 版本
EMSDK_VERSION="3.1.58"      # Emscripten SDK 版本

# 编解码器（0=关闭，1=开启）
ENABLE_H264_DECODER=1       # H.264 解码（播放器必需）
ENABLE_H264_ENCODER=0       # H.264 编码（默认关闭）
ENABLE_H265_DECODER=1       # H.265/HEVC 解码（播放器必需）
ENABLE_H265_ENCODER=0       # H.265/HEVC 编码（默认关闭）
ENABLE_AAC=1                # AAC 音频解码
ENABLE_OPUS=1               # Opus 音频解码

# WASM 内存
INITIAL_MEMORY=$((64*1024*1024))    # 初始 64MB
MAXIMUM_MEMORY=$((2*1024*1024*1024)) # 最大 2GB

# 高级特性（实验性）
ENABLE_THREADS=0            # 多线程（需要 SharedArrayBuffer）
ENABLE_SIMD=0               # SIMD 优化（需要浏览器支持）
```

> 详细说明请直接查看 `build.config.sh`，每个参数都有中文注释。

---

## 在 H5 播放器中使用

### 基础用法

```html
<script src="ffmpeg-core.js"></script>
<script>
async function main() {
  // 初始化 FFmpeg WASM 实例
  const ffmpeg = await createFFmpegCore({
    // 指定 .wasm 文件的加载路径
    locateFile: (path) => `./${path}`
  });

  // 向虚拟文件系统写入视频数据
  const videoData = new Uint8Array(await fetch('video.mp4').then(r => r.arrayBuffer()));
  ffmpeg.FS('writeFile', 'input.mp4', videoData);

  // 执行解码链路校验（相当于命令行: ffmpeg -i input.mp4 -f null -）
  // 默认构建仅保留解码 / 解封装能力，不包含视频编码器
  ffmpeg.callMain(['-i', 'input.mp4', '-f', 'null', '-']);
}
main();
</script>
```

### 在 Web Worker 中使用（推荐，避免阻塞主线程）

```javascript
// worker.js
importScripts('ffmpeg-core.js');

self.onmessage = async (e) => {
  const { inputData, inputName } = e.data;

  const ffmpeg = await createFFmpegCore({
    locateFile: (path) => `./${path}`
  });

  ffmpeg.FS('writeFile', inputName, inputData);
  ffmpeg.callMain(['-i', inputName, '-f', 'null', '-']);

  self.postMessage({ ok: true });
};
```

---

## Release 产物说明

每次通过 GitHub Actions 编译成功后，会自动创建一个 GitHub Release，包含：

| 文件 | 说明 |
|---|---|
| `ffmpeg-core.js` | JavaScript 胶水代码，加载并初始化 WASM 模块 |
| `ffmpeg-core.wasm` | WebAssembly 二进制，包含 FFmpeg 编解码逻辑 |
| `SHA256SUMS.txt` | 文件 SHA256 摘要，用于完整性校验 |

---

## 常见问题

**Q: 编译需要多长时间？**  
A: 默认解码版由于不编译 libx264/libx265，通常会比完整编解码版快很多；若手动开启编码器，首次完整编译通常仍需 20~60 分钟（取决于 CI runner 性能）。

**Q: 生成的 wasm 文件有多大？**  
A: 默认解码版会明显小于包含 libx264/libx265 的完整编解码版。可以继续通过关闭不需要的解码器、解析器和容器格式来减小体积。

**Q: 浏览器报 SharedArrayBuffer 错误怎么办？**  
A: 将 `ENABLE_THREADS` 设为 `0`（默认），或在服务器响应头中添加：  
`Cross-Origin-Opener-Policy: same-origin`  
`Cross-Origin-Embedder-Policy: require-corp`

**Q: 如何只更新某个编解码器配置？**  
A: 修改 `build.config.sh` 后，运行 `./build.sh --skip-deps`（跳过依赖库重新编译）。

---

## 许可证

本项目构建脚本采用 MIT 许可证。  
默认解码版 FFmpeg 产物采用 LGPL 2.1+；如手动启用 libx264/libx265 等 GPL 组件，则整体许可证会升级为 GPL。  
详见 [FFmpeg License](https://ffmpeg.org/legal.html)。
