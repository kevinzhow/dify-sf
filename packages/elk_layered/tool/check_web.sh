#!/usr/bin/env bash
set -euo pipefail
# Run from the package root, under the caller's CPU/memory limits.
dart run tool/generate_web_check.dart
dart compile js -O2 .dart_tool/web_check.dart -o .dart_tool/web_check.js
if command -v node >/dev/null; then
  node --eval 'globalThis.self=globalThis;require(process.cwd()+"/.dart_tool/web_check.js")'
else
  docker run --rm --user "$(id -u):$(id -g)" \
    --memory=512m --memory-swap=512m --cpus=1 \
    -v "$PWD:/work:ro" --entrypoint node "${1:-node:22-alpine}" \
    --eval 'globalThis.self=globalThis;require("/work/.dart_tool/web_check.js")'
fi
