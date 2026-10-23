#!/usr/bin/env bash
# Default web release: self-hosted Dart Wasm + skwasm, with Flutter's browser fallback.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_dir/tool/fonts/check_metrics.py"
cd "$repo_dir/app"
exec flutter build web --release "$@" --wasm --no-web-resources-cdn
