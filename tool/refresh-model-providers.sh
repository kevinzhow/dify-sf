#!/usr/bin/env bash
# Refreshes the vendored model provider definitions (server/Sources/CollabModels/Resources/dify-official-plugins) from
# github.com/langgenius/dify-official-plugins at a given commit, and prints what changed.
#
#   tool/refresh-model-providers.sh <commit>
#
# Only data is copied, unchanged: each plugin's manifest.yaml, provider/*.yaml, models/**/*.yaml (incl. _position.yaml) and
# the icon files its provider YAML names (icon_small, icon_small_dark). No Python. The repository's LICENSE (Apache-2.0) is
# copied too and SOURCE.md records the commit and every plugin's version. To vendor another provider, add its plugin
# directory name to PLUGINS (in display order) and to ModelCatalog.displayOrder.
set -euo pipefail
commit=${1:?usage: $0 <commit of langgenius/dify-official-plugins>}
PLUGINS=(openai anthropic gemini azure_openai tongyi zhipuai moonshot deepseek ollama openai_api_compatible)
here=$(cd "$(dirname "$0")/.." && pwd)
dest="$here/server/Sources/CollabModels/Resources/dify-official-plugins"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --filter=blob:none --no-checkout https://github.com/langgenius/dify-official-plugins.git "$work/repo"
git -C "$work/repo" sparse-checkout init --no-cone
patterns=(/LICENSE)
for p in "${PLUGINS[@]}"; do patterns+=("/models/$p/manifest.yaml" "/models/$p/provider/*.yaml" "/models/$p/models/**/*.yaml" "/models/$p/_assets/"); done
git -C "$work/repo" sparse-checkout set "${patterns[@]}"
git -C "$work/repo" checkout -q "$commit"
full=$(git -C "$work/repo" rev-parse HEAD)
date=$(git -C "$work/repo" show -s --format=%cs HEAD)

new="$work/new"
mkdir -p "$new"
cp "$work/repo/LICENSE" "$new/LICENSE"
for p in "${PLUGINS[@]}"; do
  src="$work/repo/models/$p"
  [ -d "$src" ] || { echo "plugin $p not found at $full" >&2; exit 1; }
  mkdir -p "$new/$p/provider" "$new/$p/_assets"
  cp "$src/manifest.yaml" "$new/$p/"
  cp "$src"/provider/*.yaml "$new/$p/provider/"
  if [ -d "$src/models" ]; then (cd "$src" && find models -name '*.yaml' -print0 | xargs -0 -r cp --parents -t "$new/$p/"); fi
  # the icons the provider YAML names (icon_small / icon_small_dark, any language)
  for icon in $(awk '/^[^ ]/ { on = ($1 == "icon_small:" || $1 == "icon_small_dark:") ; next }
                     on && /^  [A-Za-z_]+:/ { v = $2; gsub(/"/, "", v); print v }' "$src"/provider/*.yaml | sort -u); do
    cp "$src/_assets/$icon" "$new/$p/_assets/"
  done
done

{
  echo "# Vendored model provider definitions"
  echo
  echo "Data files copied unchanged from https://github.com/langgenius/dify-official-plugins (Apache License 2.0, see"
  echo "LICENSE), commit \`$full\` ($date), by \`tool/refresh-model-providers.sh\`. dify-sf reads them at startup"
  echo "(\`CollabModels\`); every adaptation (parameter templates, positions, label fallbacks) happens in code, not here."
  echo
  echo "| plugin | version | provider |"
  echo "|---|---|---|"
  for p in "${PLUGINS[@]}"; do
    v=$(sed -n -E 's/^version: *"?([^"]+)"?$/\1/p' "$new/$p/manifest.yaml" | head -1)
    prov=$(sed -n -E 's/^provider: *"?([^"]+)"?$/\1/p' "$new/$p"/provider/*.yaml | head -1)
    echo "| $p | $v | langgenius/$p/$prov |"
  done
} > "$new/SOURCE.md"

if [ -d "$dest" ]; then
  echo "changes against the current copy:"
  diff -rq "$dest" "$new" | sed -E "s#$dest#current#g; s#$new#new#g" || true
fi
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -r "$new" "$dest"
echo "vendored $full: $(find "$dest" -type f | wc -l) files, $(du -sh "$dest" | cut -f1)"
