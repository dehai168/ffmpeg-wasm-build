#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_JS="${1:-$ROOT_DIR/output/ffmpeg-core.js}"

if [ ! -f "$CORE_JS" ]; then
  echo "ffmpeg-core.js not found: $CORE_JS" >&2
  exit 1
fi

missing=0
for symbol in _malloc _free; do
  if ! grep -q "$symbol" "$CORE_JS"; then
    echo "missing symbol in ffmpeg-core.js: $symbol"
    missing=1
  fi
done

# Require a real wasm export stub, not only post-js references like Module._iov_decoder_decode(...)
if ! grep -Eq 'Module\["_iov_decoder_decode"\]|var _iov_decoder_decode=Module' "$CORE_JS"; then
  echo "missing wasm export stub for _iov_decoder_decode (post-js alone is not enough)"
  missing=1
fi

if ! grep -q 'createFFmpegCore' "$CORE_JS" && ! grep -q 'var Module=typeof Module' "$CORE_JS"; then
  echo "missing createFFmpegCore factory or global Module export"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  echo "ffmpeg-core.js is not a valid iov-h5player decoder build." >&2
  exit 1
fi

echo "ffmpeg-core.js looks valid for iov-h5player."
