# ffmpeg-wasm-build

将 FFmpeg 编译为 **WebAssembly (WASM)**，供 H5 播放器在浏览器端直接调用，支持 **H.264 / H.265** 编解码。

---

## 特性

| 功能 | 说明 |
|---|---|
| H.264 解码 | 内置软件解码器，无需外部库 |
| H.264 编码 | 集成 libx264（可通过配置开关）|
| H.265/HEVC 解码 | 内置软件解码器，无需外部库 |
| H.265/HEVC 编码 | 集成 libx265（可通过配置开关）|
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
│   ├── build-deps.sh        # 编译 libx264 / libx265（WASM 静态库）
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

# 开始编译（首次约需 20~60 分钟，视机器性能而定）
./build.sh

# 清理后重新编译
./build.sh --clean
```

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
ENABLE_H264_ENCODER=1       # H.264 编码（需要 libx264，增加编译时间）
ENABLE_H265_DECODER=1       # H.265/HEVC 解码（播放器必需）
ENABLE_H265_ENCODER=1       # H.265/HEVC 编码（需要 libx265，编译时间较长）

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

  // 执行转码（相当于命令行: ffmpeg -i input.mp4 -c:v libx264 output.mp4）
  ffmpeg.callMain(['-i', 'input.mp4', '-c:v', 'libx264', 'output.mp4']);

  // 读取输出文件
  const output = ffmpeg.FS('readFile', 'output.mp4');
  const url = URL.createObjectURL(new Blob([output], { type: 'video/mp4' }));

  document.querySelector('video').src = url;
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
  ffmpeg.callMain(['-i', inputName, '-c:v', 'libx264', 'output.mp4']);
  const output = ffmpeg.FS('readFile', 'output.mp4');

  self.postMessage({ output }, [output.buffer]);
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
A: 首次完整编译（含 libx264/libx265）约需 20~60 分钟（取决于 CI runner 性能）。开启缓存后，第二次编译只需 5~15 分钟。

**Q: 生成的 wasm 文件有多大？**  
A: 启用 H.264+H.265 编解码的完整版约 8~15 MB（gzip 后约 3~6 MB）。可以通过关闭不需要的编解码器和格式减小体积。

**Q: 浏览器报 SharedArrayBuffer 错误怎么办？**  
A: 将 `ENABLE_THREADS` 设为 `0`（默认），或在服务器响应头中添加：  
`Cross-Origin-Opener-Policy: same-origin`  
`Cross-Origin-Embedder-Policy: require-corp`

**Q: 如何只更新某个编解码器配置？**  
A: 修改 `build.config.sh` 后，运行 `./build.sh --skip-deps`（跳过依赖库重新编译）。

---

## 许可证

本项目构建脚本采用 MIT 许可证。  
FFmpeg 本身采用 LGPL 2.1+（启用 GPL 组件如 libx264/libx265 后升级为 GPL 2+）。  
详见 [FFmpeg License](https://ffmpeg.org/legal.html)。
