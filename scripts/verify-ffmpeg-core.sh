#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_JS="${1:-$ROOT_DIR/output/ffmpeg-core.js}"
CORE_WASM="${2:-${CORE_JS%.js}.wasm}"

if [ ! -f "$CORE_JS" ]; then
  echo "ffmpeg-core.js not found: $CORE_JS" >&2
  exit 1
fi

if [ ! -f "$CORE_WASM" ]; then
  echo "ffmpeg-core.wasm not found: $CORE_WASM" >&2
  exit 1
fi

missing=0

if ! grep -q 'Module\["_malloc"\]' "$CORE_JS" && ! grep -q 'Module\["_iov_wasm_malloc"\]' "$CORE_JS"; then
  echo "missing wasm export stub for heap allocator (_malloc or _iov_wasm_malloc)"
  missing=1
fi

if ! grep -q 'Module\["_free"\]' "$CORE_JS" && ! grep -q 'Module\["_iov_wasm_free"\]' "$CORE_JS"; then
  echo "missing wasm export stub for heap free (_free or _iov_wasm_free)"
  missing=1
fi

if ! grep -Eq 'Module\["_iov_decoder_decode"\]|var _iov_decoder_decode=Module' "$CORE_JS"; then
  echo "missing wasm export stub for _iov_decoder_decode (post-js alone is not enough)"
  missing=1
fi

if ! grep -q 'Module\["_iov_decoder_frame_is_video"\]' "$CORE_JS"; then
  echo "missing wasm export stub for _iov_decoder_frame_is_video"
  missing=1
fi

if ! grep -q 'createFFmpegCore' "$CORE_JS" && ! grep -q 'var Module=typeof Module' "$CORE_JS"; then
  echo "missing createFFmpegCore factory or global Module export"
  missing=1
fi

if grep -q 'Module\.iovDecoder' "$CORE_JS" || grep -q 'bindWasmHeapApi' "$CORE_JS"; then
  echo "warning: ffmpeg-core.js still embeds legacy post-js glue; rebuild with latest build-ffmpeg.sh"
fi

js_mtime=$(stat -c %Y "$CORE_JS" 2>/dev/null || stat -f %m "$CORE_JS")
wasm_mtime=$(stat -c %Y "$CORE_WASM" 2>/dev/null || stat -f %m "$CORE_WASM")
delta=$(( js_mtime > wasm_mtime ? js_mtime - wasm_mtime : wasm_mtime - js_mtime ))
if [ "$delta" -gt 5 ]; then
  echo "warning: ffmpeg-core.js and ffmpeg-core.wasm timestamps differ by ${delta}s; copy both from the same build"
fi

if [ "$missing" -ne 0 ]; then
  echo "ffmpeg-core.js is not a valid iov-h5player decoder build." >&2
  exit 1
fi

echo "ffmpeg-core.js looks valid for iov-h5player."
