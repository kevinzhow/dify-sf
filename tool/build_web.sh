#!/usr/bin/env bash
# Self-hosted Dart Wasm + CanvasKit fallback, using an isolated pinned web SDK.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
font_python=${FONTTOOLS_PYTHON:-python3}
flutter_bin=$(command -v flutter)
flutter_root=$(dirname -- "$(dirname -- "$(readlink -f -- "$flutter_bin")")")
font_dir="$repo_dir/app/assets/fonts/subsets"
if [ ! -f "$font_dir/catalog.json" ]; then
  "$font_python" "$repo_dir/tool/fonts/subset.py"
fi
python3 "$repo_dir/tool/fonts/check_metrics.py"
python3 "$repo_dir/tool/web_engine/fetch_fallbacks.py" \
  --sdk "$flutter_root/bin/cache/flutter_web_sdk" \
  --output "$repo_dir/app/web/font-fallback" \
  --lock "$repo_dir/tool/web_engine/fallback_fonts.lock.json"
# A changed patch/SDK receives a new directory, preserving earlier build evidence.
engine_key=$(python3 - "$repo_dir" "$flutter_root" <<'PY'
import hashlib,sys
from pathlib import Path
repo=Path(sys.argv[1]);flutter=Path(sys.argv[2]);h=hashlib.sha256()
for path in [repo/'tool/web_engine/build.py',repo/'tool/web_engine/dify_font_fallback.dart',flutter/'bin/cache/flutter.version.json',flutter/'bin/cache/flutter_web_sdk/lib/_engine/engine/font_fallback_service.dart']:
 h.update(path.read_bytes())
print(h.hexdigest()[:16])
PY
)
engine_src=${DIFY_ENGINE_SOURCE_ROOT:-"$repo_dir/.dart_tool/dify-engine/src"}
engine_name="dify-web-$engine_key"
engine_out="$engine_src/out/$engine_name"
if [ ! -f "$engine_out/dify-font-proof.json" ]; then
  python3 "$repo_dir/tool/web_engine/build.py" --flutter "$flutter_root" --output "$engine_out"
fi
# Keep the small document shell in sync with the existing shared design values.
python3 "$repo_dir/tool/gen_web_startup.py" --check
revision=${DIFY_RELEASE_REVISION:-development}
args=("$@")
output="$repo_dir/app/build/web"
for ((i=0;i<${#args[@]};i++)); do
  case "${args[$i]}" in
    --output) output="${args[$((i+1))]}";;
    --output=*) output="${args[$i]#--output=}";;
  esac
done
cd "$repo_dir/app"
flutter --local-engine-src-path="$engine_src" --local-web-sdk="$engine_name" build web --release \
  "${args[@]}" --wasm --no-web-resources-cdn --dart-define="DIFY_BUILD_REVISION=$revision"
if [ "$revision" != development ]; then
  python3 "$repo_dir/tool/release_manifest.py" --web "$output" --revision "$revision" --engine-proof "$engine_out/dify-font-proof.json"
  python3 "$repo_dir/tool/release_manifest.py" --web "$output" --check
fi
