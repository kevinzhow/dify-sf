#!/usr/bin/env bash
# Runs `swift <args>` inside the official Swift image with this package mounted.
# Example: ./run-swift.sh test        |  ./run-swift.sh run -c release collab-sim --runs 20000
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${SWIFT_IMAGE:-swift:6.4}"
exec docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e SWIFT_DETERMINISTIC_HASHING=1 \
  -v "$PWD":/work -w /work "$IMAGE" swift "$@"
