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
# 步骤 2：构建 FFmpeg configure 参数（填充全局数组 CONFIGURE_ARGS）
# =============================================================================
CONFIGURE_ARGS=()
build_configure_args() {
  # FFmpeg 6.1+ fftools/ffmpeg_dec.c uses pthread_t unconditionally, so -pthread
  # must always be present.  ENABLE_THREADS only controls the thread-pool size.
  # NOTE: these values contain spaces; they are stored as single array elements
  # and must be expanded with "${CONFIGURE_ARGS[@]}" — never via word-split string.
  CONFIGURE_ARGS=(
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
    # 额外 C 编译参数：值中含空格，必须作为整体传递（数组元素）
    "--extra-cflags=-I${DEPS_DIR}/include -pthread"
    "--extra-cxxflags=-I${DEPS_DIR}/include -pthread"
    "--extra-ldflags=-L${DEPS_DIR}/lib -pthread"
    # 避免 ffmpeg_g 在 pthread 构建下使用 Emscripten 默认 16MB 初始内存导致链接失败
    "--extra-ldexeflags=-sINITIAL_MEMORY=${INITIAL_MEMORY:-67108864}"
  )

  if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ] || [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-gpl" "--enable-version3")
  fi

  # ---- 网络协议 ----
  if [ "${ENABLE_NETWORK:-0}" -eq 0 ]; then
    CONFIGURE_ARGS+=("--disable-network")
  fi

  # ---- H.264 ----
  if [ "${ENABLE_H264_DECODER:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=h264")
    CONFIGURE_ARGS+=("--enable-parser=h264")
  fi
  if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-libx264" "--enable-encoder=libx264")
  fi

  # ---- H.265/HEVC ----
  if [ "${ENABLE_H265_DECODER:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=hevc")
    CONFIGURE_ARGS+=("--enable-parser=hevc")
  fi
  if [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-libx265" "--enable-encoder=libx265")
  fi

  # ---- AAC ----
  if [ "${ENABLE_AAC:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=aac" "--enable-decoder=aac_latm")
    CONFIGURE_ARGS+=("--enable-parser=aac" "--enable-parser=aac_latm")
  fi

  # ---- MP3 ----
  if [ "${ENABLE_MP3:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=mp3" "--enable-decoder=mp3float")
    CONFIGURE_ARGS+=("--enable-parser=mpegaudio")
  fi

  # ---- Opus ----
  if [ "${ENABLE_OPUS:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=opus")
    CONFIGURE_ARGS+=("--enable-parser=opus")
  fi

  # ---- VP8/VP9 ----
  if [ "${ENABLE_VP8_VP9:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-decoder=vp8" "--enable-decoder=vp9")
    CONFIGURE_ARGS+=("--enable-parser=vp8" "--enable-parser=vp9")
  fi

  # ---- 容器格式 ----
  if [ "${ENABLE_FMT_MP4:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-demuxer=mov,mp4,m4a,3gp,3g2,mj2")
    CONFIGURE_ARGS+=("--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MKV:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-demuxer=matroska")
  fi
  if [ "${ENABLE_FMT_FLV:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-demuxer=flv" "--enable-demuxer=live_flv")
  fi
  if [ "${ENABLE_FMT_HLS:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-demuxer=hls" "--enable-protocol=file")
  fi
  if [ "${ENABLE_FMT_MPEGTS:-0}" -eq 1 ]; then
    CONFIGURE_ARGS+=("--enable-demuxer=mpegts" "--enable-demuxer=mpegtsraw")
  fi

  # 保留极小的 null muxer，便于在浏览器中做解码冒烟验证
  CONFIGURE_ARGS+=("--enable-muxer=null")
}

# =============================================================================
# 步骤 3：构建 emcc 链接参数（填充全局数组 EMCC_LINK_FLAGS，最终生成 .js + .wasm）
# =============================================================================
EMCC_LINK_FLAGS=()
build_emcc_link_flags() {
  EMCC_LINK_FLAGS=(
    "-s MODULARIZE=1"
    "-s EXPORT_NAME=${EXPORT_NAME:-createFFmpegCore}"
    "-s ALLOW_MEMORY_GROWTH=${ALLOW_MEMORY_GROWTH:-1}"
    "-s INITIAL_MEMORY=${INITIAL_MEMORY:-67108864}"
    "-s MAXIMUM_MEMORY=${MAXIMUM_MEMORY:-2147483648}"
    # 导出供 JS 调用的函数（使用 response file，避免命令行过长被截断）
    "-s EXPORTED_FUNCTIONS=@$SCRIPT_DIR/iov/wasm-exports.json"
    # 确保 libc malloc/free 被链接并可供 EXPORTED_FUNCTIONS 导出
    "-s DEFAULT_LIBRARY_FUNCS_TO_INCLUDE=[\"\$malloc\",\"\$free\"]"
    # 导出运行时方法：FS（虚拟文件系统）、callMain（调用 main）
    "-s EXPORTED_RUNTIME_METHODS=[\"FS\",\"callMain\",\"ccall\",\"cwrap\",\"HEAPU8\",\"UTF8ToString\",\"stringToNewUTF8\"]"
    # 目标环境：web + worker（兼容主线程和 Web Worker）
    "-s ENVIRONMENT=web,worker"
    # 允许使用 SDL 等 Emscripten 内置 API（此处关闭减少体积）
    "-s USE_SDL=0"
    # Do not run ffmpeg CLI main() on load; iov-h5player only needs exported decoder APIs.
    "-s INVOKE_RUN=0"
    # 关闭 Emscripten 自带的异常处理（FFmpeg 不使用 C++ 异常）
    "-s DISABLE_EXCEPTION_CATCHING=1"
    # 错误处理：遇到 abort 时尽量给出有用信息
    "-s ASSERTIONS=0"
  )

  # ---- 线程支持 ----
  # FFmpeg 6.1+ fftools require pthreads; USE_PTHREADS is always needed.
  # ENABLE_THREADS controls the pool size: 0 → 1 (minimal), 1 → configured value.
  local _pool_size=1
  [ "${ENABLE_THREADS:-0}" -eq 1 ] && _pool_size="${PTHREAD_POOL_SIZE:-4}"
  EMCC_LINK_FLAGS+=(
    "-s USE_PTHREADS=1"
    "-s PTHREAD_POOL_SIZE=${_pool_size}"
  )

  # ---- SIMD 优化 ----
  if [ "${ENABLE_SIMD:-0}" -eq 1 ]; then
    EMCC_LINK_FLAGS+=("-msimd128")
  fi

  # ---- 调试模式 ----
  if [ "${ENABLE_DEBUG:-0}" -eq 1 ]; then
    EMCC_LINK_FLAGS+=("-O0" "-g" "-s ASSERTIONS=2" "--source-map-base ./")
  else
    EMCC_LINK_FLAGS+=("-O3")
  fi
}

# =============================================================================
# 主流程
# =============================================================================

download_ffmpeg

cd "$FFMPEG_SRC"

# ---- 配置 FFmpeg（使用 emconfigure 注入 Emscripten 工具链）-----------------
log_info "配置 FFmpeg (emconfigure)..."
build_configure_args
emconfigure ./configure "${CONFIGURE_ARGS[@]}"

# ---- 编译 FFmpeg（仅编译为 .a 和 .o，不链接）--------------------------------
log_info "编译 FFmpeg 库文件 (emmake make, jobs=$MAKE_JOBS)..."
# 编译静态库和 ffmpeg CLI 相关对象文件，最终由 emcc 手动链接为 WASM
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

# 某些配置下（如 --target-os=none）make 不会生成 fftools 目标文件，
# 因为此时 Makefile 中不存在 "ffmpeg" 可执行目标。直接用 emcc 编译各 .c 源文件。
if [ ! -f "$FFMPEG_SRC/fftools/cmdutils.o" ] || [ ! -f "$FFMPEG_SRC/fftools/opt_common.o" ]; then
  log_warn "fftools 目标文件不完整，直接编译 fftools 源文件..."
  # 读取 configure 生成的 CFLAGS（含 -std=、-D 宏等），缺失时静默忽略
  _ffbuild_cflags=""
  if [ -f "$FFMPEG_SRC/ffbuild/config.mak" ]; then
    _ffbuild_cflags=$(sed -n 's/^CFLAGS=//p' "$FFMPEG_SRC/ffbuild/config.mak" | head -1)
  fi
  # FFmpeg 6.1+ fftools require pthreads unconditionally.
  _thread_flag="-pthread"
  for src in "$FFMPEG_SRC/fftools/"*.c; do
    obj="${src%.c}.o"
    [ -f "$obj" ] && continue
    log_info "编译 fftools/$(basename "$src")..."
    # shellcheck disable=SC2086
    emcc -c "$src" \
      -I"$FFMPEG_SRC" \
      -I"$FFMPEG_SRC/fftools" \
      -I"$FFMPEG_BUILD_DIR/include" \
      -I"$DEPS_DIR/include" \
      $_thread_flag \
      $_ffbuild_cflags \
      -o "$obj"
  done
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

IOV_DECODER_SRC="$SCRIPT_DIR/iov/iov_decoder.c"
IOV_DECODER_OBJ="$SCRIPT_DIR/iov/iov_decoder.o"

if [ ! -f "$IOV_DECODER_SRC" ]; then
  log_error "未找到 iov decoder 源文件: $IOV_DECODER_SRC"
  exit 1
fi

log_info "编译 iov decoder..."
_thread_flag="-pthread"
_ffbuild_cflags=""
if [ -f "$FFMPEG_SRC/ffbuild/config.mak" ]; then
  _ffbuild_cflags=$(sed -n 's/^CFLAGS=//p' "$FFMPEG_SRC/ffbuild/config.mak" | head -1)
fi
rm -f "$IOV_DECODER_OBJ"
# shellcheck disable=SC2086
emcc -c "$IOV_DECODER_SRC" \
  -I"$FFMPEG_BUILD_DIR/include" \
  -I"$DEPS_DIR/include" \
  $_thread_flag \
  $_ffbuild_cflags \
  -o "$IOV_DECODER_OBJ"

# ---- 最终 emcc 链接：生成 ffmpeg-core.js + ffmpeg-core.wasm ----------------
log_info "链接生成 WASM 产物..."
build_emcc_link_flags
OUTPUT_JS="$OUTPUT_DIR/${OUTPUT_NAME:-ffmpeg-core}.js"

emcc \
  "${FFTOOLS_OBJS[@]}" \
  "$IOV_DECODER_OBJ" \
  "${FFMPEG_LIBS[@]}" \
  "${EXTRA_LIBS[@]}" \
  -I"$FFMPEG_BUILD_DIR/include" \
  -I"$DEPS_DIR/include" \
  -o "$OUTPUT_JS" \
  "${EMCC_LINK_FLAGS[@]}"

log_ok "链接完成！输出文件："
ls -lh "$OUTPUT_DIR/"

if ! bash "$SCRIPT_DIR/scripts/verify-ffmpeg-core.sh" "$OUTPUT_JS" "${OUTPUT_JS%.js}.wasm"; then
  log_error "ffmpeg-core.js 未通过 iov-h5player 导出校验，请检查 iov/wasm-exports.json 与链接日志"
  exit 1
fi
