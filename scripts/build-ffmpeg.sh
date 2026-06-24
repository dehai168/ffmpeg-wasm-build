#!/usr/bin/env bash
# =============================================================================
# 下载并编译 FFmpeg → 链接为 WebAssembly (ffmpeg-core.js + ffmpeg-core.wasm)
# 此脚本由 build.sh 调用，所有配置变量已从 build.config.sh 导出。
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[ffmpeg]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ffmpeg]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[ffmpeg]${NC} $*"; }
log_error() { echo -e "${RED}[ffmpeg]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_TARBALL="$FFMPEG_SRC_DIR/../ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SRC="$FFMPEG_SRC_DIR"

# =============================================================================
# 步骤 1：下载 FFmpeg 源码
# =============================================================================
download_ffmpeg() {
  if [ -f "$FFMPEG_SRC/configure" ]; then
    log_warn "FFmpeg 源码已存在，跳过下载"
    return 0
  fi
  mkdir -p "$FFMPEG_SRC"
  log_info "下载 FFmpeg $FFMPEG_VERSION 源码..."
  curl -L --retry 3 \
    -o "$FFMPEG_TARBALL" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

  log_info "解压 FFmpeg 源码..."
  tar -xf "$FFMPEG_TARBALL" -C "$FFMPEG_SRC" --strip-components=1
  log_ok "FFmpeg 源码准备完毕: $FFMPEG_SRC"
}

# =============================================================================
# 步骤 2：构建 FFmpeg configure 参数
# =============================================================================
build_configure_args() {
  local args=(
    "--prefix=$FFMPEG_BUILD_DIR"
    # 目标平台：none 表示裸机/WASM
    "--target-os=none"
    "--arch=x86_32"
    "--enable-cross-compile"
    # 显式指定 Emscripten 工具链，确保 config.mak 中记录正确的编译器
    "--cc=emcc"
    "--cxx=em++"
    "--ar=emar"
    "--ranlib=emranlib"
    "--nm=llvm-nm"
    # 先关闭大部分组件，再按播放器所需能力逐项开启
    "--disable-everything"
    # 禁用汇编优化（WASM 不支持）
    "--disable-x86asm"
    "--disable-inline-asm"
    "--disable-asm"
    "--disable-stripping"
    "--disable-doc"
    "--disable-debug"
    "--disable-runtime-cpudetect"
    "--disable-autodetect"
    # 保留 ffmpeg 工具作为 WASM 入口
    "--enable-ffmpeg"
    "--disable-ffprobe"
    "--disable-ffplay"
    # 额外 C 编译参数
    "--extra-cflags=-I${DEPS_DIR}/include"
    "--extra-cxxflags=-I${DEPS_DIR}/include"
    "--extra-ldflags=-L${DEPS_DIR}/lib"
  )

  if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ] || [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ]; then
    args+=("--enable-gpl" "--enable-version3")
  fi

  # ---- 网络协议 ----
  if [ "${ENABLE_NETWORK:-0}" -eq 0 ]; then
    args+=("--disable-network")
  fi

  # ---- H.264 ----
  if [ "${ENABLE_H264_DECODER:-0}" -eq 1 ]; then
    args+=("--enable-decoder=h264")
    args+=("--enable-parser=h264")
  fi
  if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ]; then
    args+=("--enable-libx264" "--enable-encoder=libx264")
  fi

  # ---- H.265/HEVC ----
  if [ "${ENABLE_H265_DECODER:-0}" -eq 1 ]; then
    args+=("--enable-decoder=hevc")
    args+=("--enable-parser=hevc")
  fi
  if [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ]; then
    args+=("--enable-libx265" "--enable-encoder=libx265")
  fi

  # ---- AAC ----
  if [ "${ENABLE_AAC:-0}" -eq 1 ]; then
    args+=("--enable-decoder=aac" "--enable-decoder=aac_latm")
    args+=("--enable-parser=aac" "--enable-parser=aac_latm")
  fi

  # ---- MP3 ----
  if [ "${ENABLE_MP3:-0}" -eq 1 ]; then
    args+=("--enable-decoder=mp3" "--enable-decoder=mp3float")
    args+=("--enable-parser=mpegaudio")
  fi

  # ---- Opus ----
  if [ "${ENABLE_OPUS:-0}" -eq 1 ]; then
    args+=("--enable-decoder=opus")
    args+=("--enable-parser=opus")
  fi

  # ---- VP8/VP9 ----
  if [ "${ENABLE_VP8_VP9:-0}" -eq 1 ]; then
    args+=("--enable-decoder=vp8" "--enable-decoder=vp9")
    args+=("--enable-parser=vp8" "--enable-parser=vp9")
  fi

  # ---- 容器格式 ----
  if [ "${ENABLE_FMT_MP4:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=mov,mp4,m4a,3gp,3g2,mj2")
    args+=("--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MKV:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=matroska")
  fi
  if [ "${ENABLE_FMT_FLV:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=flv" "--enable-demuxer=live_flv")
  fi
  if [ "${ENABLE_FMT_HLS:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=hls" "--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MPEGTS:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=mpegts" "--enable-demuxer=mpegtsraw")
  fi

  # 保留极小的 null muxer，便于在浏览器中做解码冒烟验证
  args+=("--enable-muxer=null")

  # ---- 线程 ----
  if [ "${ENABLE_THREADS:-0}" -eq 0 ]; then
    args+=("--disable-pthreads" "--disable-w32threads" "--disable-os2threads")
  fi

  echo "${args[@]}"
}

# =============================================================================
# 步骤 3：构建 emcc 链接参数（最终生成 .js + .wasm）
# =============================================================================
build_emcc_link_flags() {
  local flags=(
    "-s MODULARIZE=1"
    "-s EXPORT_NAME=${EXPORT_NAME:-createFFmpegCore}"
    "-s ALLOW_MEMORY_GROWTH=${ALLOW_MEMORY_GROWTH:-1}"
    "-s INITIAL_MEMORY=${INITIAL_MEMORY:-67108864}"
    "-s MAXIMUM_MEMORY=${MAXIMUM_MEMORY:-2147483648}"
    # 导出供 JS 调用的函数
    "-s EXPORTED_FUNCTIONS=[\"_main\"]"
    # 导出运行时方法：FS（虚拟文件系统）、callMain（调用 main）
    "-s EXPORTED_RUNTIME_METHODS=[\"FS\",\"callMain\",\"ccall\",\"cwrap\"]"
    # 目标环境：web + worker（兼容主线程和 Web Worker）
    "-s ENVIRONMENT=web,worker"
    # 允许使用 SDL 等 Emscripten 内置 API（此处关闭减少体积）
    "-s USE_SDL=0"
    # 关闭 Emscripten 自带的异常处理（FFmpeg 不使用 C++ 异常）
    "-s DISABLE_EXCEPTION_CATCHING=1"
    # 错误处理：遇到 abort 时尽量给出有用信息
    "-s ASSERTIONS=0"
  )

  # ---- 线程支持 ----
  if [ "${ENABLE_THREADS:-0}" -eq 1 ]; then
    flags+=(
      "-s USE_PTHREADS=1"
      "-s PTHREAD_POOL_SIZE=${PTHREAD_POOL_SIZE:-4}"
    )
  fi

  # ---- SIMD 优化 ----
  if [ "${ENABLE_SIMD:-0}" -eq 1 ]; then
    flags+=("-msimd128")
  fi

  # ---- 调试模式 ----
  if [ "${ENABLE_DEBUG:-0}" -eq 1 ]; then
    flags+=("-O0" "-g" "-s ASSERTIONS=2" "--source-map-base ./")
  else
    flags+=("-O3")
  fi

  echo "${flags[@]}"
}

# =============================================================================
# 主流程
# =============================================================================

download_ffmpeg

cd "$FFMPEG_SRC"

# ---- 配置 FFmpeg（使用 emconfigure 注入 Emscripten 工具链）-----------------
log_info "配置 FFmpeg (emconfigure)..."
# 读取配置参数（使用 eval 展开数组，保留含空格的参数）
CONFIGURE_ARGS=$(build_configure_args)

# shellcheck disable=SC2086
emconfigure ./configure $CONFIGURE_ARGS

# ---- 编译 FFmpeg（仅编译为 .a 和 .o，不链接）--------------------------------
log_info "编译 FFmpeg 库文件 (emmake make, jobs=$MAKE_JOBS)..."
# EXEEXT=.js 告诉 FFmpeg Makefile 最终可执行文件后缀为 .js
# 但我们用 --disable-programs 不生成可执行文件，手动链接
emmake make -j"$MAKE_JOBS"
emmake make install

# ---- 收集所有需要链接的 .a 静态库 -------------------------------------------
FFMPEG_LIBS=(
  "$FFMPEG_BUILD_DIR/lib/libavcodec.a"
  "$FFMPEG_BUILD_DIR/lib/libavformat.a"
  "$FFMPEG_BUILD_DIR/lib/libavfilter.a"
  "$FFMPEG_BUILD_DIR/lib/libavutil.a"
  "$FFMPEG_BUILD_DIR/lib/libswresample.a"
  "$FFMPEG_BUILD_DIR/lib/libswscale.a"
  "$FFMPEG_BUILD_DIR/lib/libavdevice.a"
)

EXTRA_LIBS=()
if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ] && [ -f "$DEPS_DIR/lib/libx264.a" ]; then
  EXTRA_LIBS+=("$DEPS_DIR/lib/libx264.a")
fi
if [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ] && [ -f "$DEPS_DIR/lib/libx265.a" ]; then
  EXTRA_LIBS+=("$DEPS_DIR/lib/libx265.a" "-lstdc++")
fi

# ---- 收集 fftools 目标文件（ffmpeg 命令行工具的 .o 文件）--------------------
FFTOOLS_OBJS=()
for obj in "$FFMPEG_SRC/fftools/ffmpeg.o" "$FFMPEG_SRC"/fftools/ffmpeg_*.o \
           "$FFMPEG_SRC/fftools/cmdutils.o" "$FFMPEG_SRC/fftools/opt_common.o" \
           "$FFMPEG_SRC/fftools/objpool.o" "$FFMPEG_SRC/fftools/sync_queue.o" \
           "$FFMPEG_SRC/fftools/thread_queue.o"; do
  [ -f "$obj" ] && FFTOOLS_OBJS+=("$obj")
done

# 某些配置下默认 make 不会生成完整的 fftools 依赖，补编译一次 ffmpeg 目标
if [ ! -f "$FFMPEG_SRC/fftools/cmdutils.o" ] || [ ! -f "$FFMPEG_SRC/fftools/opt_common.o" ]; then
  log_warn "fftools 目标文件不完整，尝试补编译 fftools/ffmpeg..."
  emmake make -j"$MAKE_JOBS" fftools/ffmpeg || true
  FFTOOLS_OBJS=()
  for obj in "$FFMPEG_SRC/fftools/ffmpeg.o" "$FFMPEG_SRC"/fftools/ffmpeg_*.o \
             "$FFMPEG_SRC/fftools/cmdutils.o" "$FFMPEG_SRC/fftools/opt_common.o" \
             "$FFMPEG_SRC/fftools/objpool.o" "$FFMPEG_SRC/fftools/sync_queue.o" \
             "$FFMPEG_SRC/fftools/thread_queue.o"; do
    [ -f "$obj" ] && FFTOOLS_OBJS+=("$obj")
  done
fi

if [ ${#FFTOOLS_OBJS[@]} -eq 0 ]; then
  log_error "未找到可链接的 fftools 目标文件"
  exit 1
fi

# ---- 最终 emcc 链接：生成 ffmpeg-core.js + ffmpeg-core.wasm ----------------
log_info "链接生成 WASM 产物..."
EMCC_LINK_FLAGS=$(build_emcc_link_flags)
OUTPUT_JS="$OUTPUT_DIR/${OUTPUT_NAME:-ffmpeg-core}.js"

# shellcheck disable=SC2086
emcc \
  "${FFTOOLS_OBJS[@]}" \
  "${FFMPEG_LIBS[@]}" \
  "${EXTRA_LIBS[@]}" \
  -I"$FFMPEG_BUILD_DIR/include" \
  -I"$DEPS_DIR/include" \
  -o "$OUTPUT_JS" \
  $EMCC_LINK_FLAGS

log_ok "链接完成！输出文件："
ls -lh "$OUTPUT_DIR/"
