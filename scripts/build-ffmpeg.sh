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
  log_info "下载 FFmpeg $FFMPEG_VERSION 源码..."
  curl -L --retry 3 \
    -o "$FFMPEG_TARBALL" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

  log_info "解压 FFmpeg 源码..."
  mkdir -p "$FFMPEG_SRC"
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
    # 禁用汇编优化（WASM 不支持）
    "--disable-x86asm"
    "--disable-inline-asm"
    "--disable-asm"
    "--disable-stripping"
    "--disable-doc"
    "--disable-debug"
    "--disable-runtime-cpudetect"
    "--disable-autodetect"
    # 允许使用 GPL 许可证组件（libx264/libx265 需要）
    "--enable-gpl"
    "--enable-version3"
    # 启用 ffmpeg 工具（编译 fftools/*.c）
    "--enable-ffmpeg"
    "--disable-ffprobe"
    "--disable-ffplay"
    # 额外 C 编译参数
    "--extra-cflags=-I${DEPS_DIR}/include"
    "--extra-cxxflags=-I${DEPS_DIR}/include"
    "--extra-ldflags=-L${DEPS_DIR}/lib"
  )

  # ---- 网络协议 ----
  if [ "${ENABLE_NETWORK:-0}" -eq 0 ]; then
    args+=("--disable-network")
  fi

  # ---- H.264 ----
  if [ "${ENABLE_H264_DECODER:-0}" -eq 1 ]; then
    args+=("--enable-decoder=h264" "--enable-decoder=h264_v4l2m2m")
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
    args+=("--enable-encoder=aac")
    args+=("--enable-parser=aac" "--enable-parser=aac_latm")
  fi

  # ---- MP3 ----
  if [ "${ENABLE_MP3:-0}" -eq 1 ]; then
    args+=("--enable-decoder=mp3" "--enable-decoder=mp3float")
    args+=("--enable-parser=mpegaudio")
  fi

  # ---- Opus ----
  if [ "${ENABLE_OPUS:-0}" -eq 1 ]; then
    args+=("--enable-decoder=opus" "--enable-encoder=opus")
    args+=("--enable-parser=opus")
  fi

  # ---- VP8/VP9 ----
  if [ "${ENABLE_VP8_VP9:-0}" -eq 1 ]; then
    args+=("--enable-decoder=vp8" "--enable-decoder=vp9")
    args+=("--enable-parser=vp8" "--enable-parser=vp9")
  fi

  # ---- 容器格式 ----
  if [ "${ENABLE_FMT_MP4:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=mov,mp4,m4a,3gp,3g2,mj2" "--enable-muxer=mp4" "--enable-muxer=mov")
    args+=("--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MKV:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=matroska" "--enable-muxer=matroska" "--enable-muxer=webm")
  fi
  if [ "${ENABLE_FMT_FLV:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=flv" "--enable-muxer=flv" "--enable-demuxer=live_flv")
  fi
  if [ "${ENABLE_FMT_HLS:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=hls" "--enable-muxer=hls" "--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MPEGTS:-0}" -eq 1 ]; then
    args+=("--enable-demuxer=mpegts" "--enable-demuxer=mpegtsraw" "--enable-muxer=mpegts")
  fi

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
    "-s EXPORTED_FUNCTIONS=[\"_main\",\"_proxy_main\"]"
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
for obj in fftools/ffmpeg.o fftools/ffmpeg_opt.o fftools/ffmpeg_filter.o \
           fftools/ffmpeg_hw.o fftools/cmdutils.o fftools/objpool.o \
           fftools/sync_queue.o fftools/thread_queue.o; do
  [ -f "$FFMPEG_SRC/$obj" ] && FFTOOLS_OBJS+=("$FFMPEG_SRC/$obj")
done

# 如果 fftools 对象文件不存在（disable-programs 情况），手动编译
if [ ${#FFTOOLS_OBJS[@]} -eq 0 ]; then
  log_warn "未找到 fftools .o 文件，尝试单独编译 fftools..."
  emcc -c "$FFMPEG_SRC/fftools/ffmpeg.c" \
    -I"$FFMPEG_SRC" -I"$FFMPEG_BUILD_DIR/include" -I"$DEPS_DIR/include" \
    -DFFMPEG_MAIN=ffmpeg_main \
    -o /tmp/ffmpeg_main.o 2>/dev/null || true

  # 使用已有的编译配置重新生成 fftools
  cd "$FFMPEG_SRC"
  emmake make -j"$MAKE_JOBS" fftools/ffmpeg.o fftools/ffmpeg_opt.o \
    fftools/ffmpeg_filter.o fftools/cmdutils.o 2>/dev/null || true
  for obj in fftools/ffmpeg.o fftools/ffmpeg_opt.o fftools/ffmpeg_filter.o \
             fftools/cmdutils.o; do
    [ -f "$FFMPEG_SRC/$obj" ] && FFTOOLS_OBJS+=("$FFMPEG_SRC/$obj")
  done
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
