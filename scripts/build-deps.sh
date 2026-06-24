#!/usr/bin/env bash
# =============================================================================
# 编译依赖库为 WebAssembly 静态库
#   - libx264：H.264 编码器（ENABLE_H264_ENCODER=1 时编译）
#   - libx265：H.265/HEVC 编码器（ENABLE_H265_ENCODER=1 时编译）
# 此脚本由 build.sh 调用，所有配置变量已从 build.config.sh 导出。
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${CYAN}[deps]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[deps]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[deps]${NC}  $*"; }
log_error() { echo -e "${RED}[deps]${NC}  $*" >&2; }

DEPS_SRC_DIR="$(dirname "$DEPS_DIR")/deps-src"
mkdir -p "$DEPS_SRC_DIR"

# =============================================================================
# 辅助：检查缓存，避免重复编译
# =============================================================================
is_cached() {
  local marker="$DEPS_DIR/.built_$1"
  [ -f "$marker" ]
}

mark_cached() {
  touch "$DEPS_DIR/.built_$1"
}

# =============================================================================
# libx264 — H.264 编码器
# =============================================================================
build_x264() {
  if is_cached "x264_${X264_VERSION}"; then
    log_warn "libx264 已有缓存，跳过编译"
    return 0
  fi

  log_info "--- 下载 libx264 (branch: $X264_VERSION) ---"
  local src_dir="$DEPS_SRC_DIR/x264"

  if [ -d "$src_dir" ]; then
    log_info "使用已存在的 libx264 源码目录"
  else
    git clone --depth 1 --branch "$X264_VERSION" \
      https://code.videolan.org/videolan/x264.git "$src_dir"
  fi

  log_info "--- 编译 libx264 (Emscripten 交叉编译) ---"
  cd "$src_dir"

  # 使用 emconfigure 包装 ./configure，自动替换编译器为 emcc
  emconfigure ./configure \
    --prefix="$DEPS_DIR" \
    --host=i686-gnu \
    --disable-cli \
    --enable-static \
    --disable-opencl \
    --disable-thread \
    --disable-asm \
    --disable-avs \
    --disable-swscale \
    --disable-lavf \
    --disable-ffms \
    --disable-gpac \
    --disable-lsmash \
    --extra-cflags="-Wno-error"

  emmake make -j"$MAKE_JOBS"
  emmake make install

  mark_cached "x264_${X264_VERSION}"
  log_ok "libx264 编译完成 → $DEPS_DIR"
}

# =============================================================================
# libx265 — H.265/HEVC 编码器
# 注意：x265 的汇编优化无法在 WASM 中使用，必须 -DENABLE_ASSEMBLY=OFF
# =============================================================================
build_x265() {
  if is_cached "x265_${X265_VERSION}"; then
    log_warn "libx265 已有缓存，跳过编译"
    return 0
  fi

  log_info "--- 下载 libx265 v$X265_VERSION ---"
  local src_dir="$DEPS_SRC_DIR/x265"
  local tarball="$DEPS_SRC_DIR/x265_${X265_VERSION}.tar.gz"
  local download_url="https://bitbucket.org/multicoreware/x265_git/downloads/x265_${X265_VERSION}.tar.gz"

  if [ ! -f "$tarball" ]; then
    curl -L --retry 3 -o "$tarball" "$download_url"
  fi
  if [ ! -d "$src_dir" ]; then
    mkdir -p "$src_dir"
    tar -xf "$tarball" -C "$src_dir" --strip-components=1
  fi

  log_info "--- 编译 libx265 (Emscripten 交叉编译) ---"
  local build_dir="$DEPS_SRC_DIR/x265-build"
  mkdir -p "$build_dir"
  cd "$build_dir"

  # emcmake 包装 cmake，注入 Emscripten 工具链
  emcmake cmake "$src_dir/source" \
    -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_ASSEMBLY=OFF \
    -DENABLE_TESTS=OFF \
    -DHIGH_BIT_DEPTH=OFF \
    -DEXPORT_C_API=ON \
    -DNATIVE_BUILD=OFF \
    -GNinja

  ninja -j"$MAKE_JOBS" install

  mark_cached "x265_${X265_VERSION}"
  log_ok "libx265 编译完成 → $DEPS_DIR"
}

# =============================================================================
# 主流程
# =============================================================================
if [ "${ENABLE_H264_ENCODER:-0}" -eq 1 ]; then
  log_info "H.264 编码器已启用，准备编译 libx264..."
  build_x264
else
  log_warn "H.264 编码器未启用（ENABLE_H264_ENCODER=0），跳过 libx264"
fi

if [ "${ENABLE_H265_ENCODER:-0}" -eq 1 ]; then
  log_info "H.265 编码器已启用，准备编译 libx265..."
  build_x265
else
  log_warn "H.265 编码器未启用（ENABLE_H265_ENCODER=0），跳过 libx265"
fi
