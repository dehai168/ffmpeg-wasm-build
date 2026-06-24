#!/usr/bin/env bash
# =============================================================================
# FFmpeg WASM 主编译入口
# 用法：./build.sh [--clean] [--skip-deps] [--skip-ffmpeg]
#   --clean       清理所有中间产物后重新编译
#   --skip-deps   跳过依赖库（libx264/libx265）的编译（已编译过时可用）
#   --skip-ffmpeg 跳过 FFmpeg 的编译（仅重新链接）
# =============================================================================
set -euo pipefail

# ---------- 彩色日志 ----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------- 加载配置 ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/build.config.sh"
ENV_OUTPUT_DIR="${OUTPUT_DIR-}"

if [ ! -f "$CONFIG_FILE" ]; then
  log_error "找不到配置文件: $CONFIG_FILE"
  exit 1
fi
# shellcheck source=build.config.sh
source "$CONFIG_FILE"

# ---------- 解析命令行参数 ---------------------------------------------------
DO_CLEAN=0
SKIP_DEPS=0
SKIP_FFMPEG=0

for arg in "$@"; do
  case "$arg" in
    --clean)        DO_CLEAN=1 ;;
    --skip-deps)    SKIP_DEPS=1 ;;
    --skip-ffmpeg)  SKIP_FFMPEG=1 ;;
    -h|--help)
      echo "用法: $0 [--clean] [--skip-deps] [--skip-ffmpeg]"
      exit 0
      ;;
    *) log_warn "未知参数: $arg，已忽略" ;;
  esac
done

# ---------- 检查 Emscripten 环境 ---------------------------------------------
if ! command -v emcc &>/dev/null; then
  log_error "未检测到 emcc，请先激活 Emscripten SDK："
  log_error "  source /path/to/emsdk/emsdk_env.sh"
  exit 1
fi
log_info "Emscripten 版本: $(emcc --version | head -1)"

# ---------- 确定并行编译线程数 -----------------------------------------------
if [ "${MAKE_JOBS:-0}" -eq 0 ]; then
  MAKE_JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
fi
log_info "并行编译线程数: $MAKE_JOBS"

export MAKE_JOBS

# ---------- 目录设置 ----------------------------------------------------------
# 依赖库安装目录（libx264, libx265 的头文件和 .a 静态库）
export DEPS_DIR="$SCRIPT_DIR/.build/deps"
# FFmpeg 源码目录
export FFMPEG_SRC_DIR="$SCRIPT_DIR/.build/ffmpeg-src"
# FFmpeg 构建目录
export FFMPEG_BUILD_DIR="$SCRIPT_DIR/.build/ffmpeg-build"
# 最终产物输出目录
if [ -n "${ENV_OUTPUT_DIR:-}" ]; then
  OUTPUT_DIR="$ENV_OUTPUT_DIR"
fi
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
case "$OUTPUT_DIR" in
  /*) ;;
  *) OUTPUT_DIR="$SCRIPT_DIR/${OUTPUT_DIR#./}" ;;
esac
export OUTPUT_DIR

# 导出所有配置，供子脚本读取
export FFMPEG_VERSION X264_VERSION X265_VERSION
export ENABLE_H264_DECODER ENABLE_H264_ENCODER
export ENABLE_H265_DECODER ENABLE_H265_ENCODER
export ENABLE_AAC ENABLE_MP3 ENABLE_OPUS ENABLE_VP8_VP9
export ENABLE_FMT_MP4 ENABLE_FMT_MKV ENABLE_FMT_FLV ENABLE_FMT_HLS ENABLE_FMT_MPEGTS
export ENABLE_NETWORK
export INITIAL_MEMORY MAXIMUM_MEMORY ALLOW_MEMORY_GROWTH
export ENABLE_THREADS PTHREAD_POOL_SIZE ENABLE_SIMD ENABLE_DEBUG
export OUTPUT_NAME EXPORT_NAME USE_ES6_MODULE
export BUILD_CACHE_DIR

# ---------- 清理 -------------------------------------------------------------
if [ "$DO_CLEAN" -eq 1 ]; then
  log_warn "清理所有中间产物..."
  rm -rf "$SCRIPT_DIR/.build"
  rm -rf "$OUTPUT_DIR"
  log_ok "清理完成"
fi

# ---------- 创建必要目录 ------------------------------------------------------
mkdir -p "$DEPS_DIR" "$FFMPEG_BUILD_DIR" "$OUTPUT_DIR" "${BUILD_CACHE_DIR:-/tmp/ffmpeg-wasm-cache}"

# ---------- 步骤 1：编译依赖库 -----------------------------------------------
if [ "$SKIP_DEPS" -eq 0 ]; then
  log_info "========== 步骤 1/2：按需编译编码依赖库（libx264 / libx265） =========="
  bash "$SCRIPT_DIR/scripts/build-deps.sh"
  log_ok "依赖库编译完成"
else
  log_warn "已跳过依赖库编译（--skip-deps）"
fi

# ---------- 步骤 2：编译 FFmpeg 并链接为 WASM --------------------------------
if [ "$SKIP_FFMPEG" -eq 0 ]; then
  log_info "========== 步骤 2/2：编译 FFmpeg → WASM =========="
  bash "$SCRIPT_DIR/scripts/build-ffmpeg.sh"
  log_ok "FFmpeg WASM 编译完成"
else
  log_warn "已跳过 FFmpeg 编译（--skip-ffmpeg）"
fi

# ---------- 完成 -------------------------------------------------------------
echo ""
log_ok "============================================================"
log_ok " 编译成功！产物位于: $OUTPUT_DIR"
log_ok "============================================================"
ls -lh "$OUTPUT_DIR/"
echo ""
log_info "JS 使用方式示例："
echo "  import createFFmpegCore from './${OUTPUT_NAME}.js';"
echo "  const ffmpeg = await createFFmpegCore();"
echo "  ffmpeg.FS('writeFile', 'input.mp4', data);"
echo "  ffmpeg.callMain(['-i', 'input.mp4', '-f', 'null', '-']);"
