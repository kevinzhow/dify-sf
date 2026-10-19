#!/usr/bin/env bash
# Records the golden traces: Dify's own engine (graphon 0.7.0 inside the langgenius/dify-api:1.17.1 image) runs the
# cases of e2e/traces/cases.json over Dify's 24 sample workflows with Dify's mock nodes; the normalized traces go to
# server/Tests/CollabTests/Fixtures/graphon-traces/. No network, 1 GiB, read-only mounts, `python -I`.
#
#   DIFY_SRC=/path/to/dify-1.17.1 e2e/traces/record.sh [--only <name part>] [--repeat N]
#
# DIFY_SRC is a checkout of Dify 1.17.1 (its api/tests holds the table runner and the mock node factory; they are not
# in the image). On a shared machine run it inside the heavy-job wrapper.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
: "${DIFY_SRC:?set DIFY_SRC to a Dify 1.17.1 checkout}"
out="$repo/server/Tests/CollabTests/Fixtures/graphon-traces"
mkdir -p "$out"
docker run --rm --network none --memory 1g --memory-swap 1g --cpus 2 \
  --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$here":/e2e:ro \
  -v "$repo/server/Tests/CollabTests/Fixtures/dify":/fixtures:ro \
  -v "$DIFY_SRC/api/tests":/app/api/tests:ro \
  -v "$out":/out \
  --entrypoint /app/api/.venv/bin/python \
  langgenius/dify-api:1.17.1 -I /e2e/traces/record_graphon.py "$@"
