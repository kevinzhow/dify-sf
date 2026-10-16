#!/usr/bin/env bash
# Runs `swift <args>` inside the dev image with the server/ package mounted.
# Example: ./run-swift.sh test   |   ./run-swift.sh build -c release
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${DEV_IMAGE:-dify-sf-dev:local}"
exec docker run --rm --memory "${DEV_MEM:-5g}" --cpus "${DEV_CPUS:-4}" --user "$(id -u):$(id -g)" -e HOME=/tmp -e SWIFT_DETERMINISTIC_HASHING=1 \
  -v "$PWD":/work -w /work "$IMAGE" swift "$@"
