#!/usr/bin/env bash
# Run inside the machine's normal resource-limited test job, from any directory.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
python3 tool/fonts/check_metrics.py
python3 tool/design/check_control_coverage.py
python3 tool/design/check.py
cd app
flutter analyze --no-pub
# Includes actual-font primitives, the shared gallery, application call sites,
# popup/dialog/table compositions, accessibility and existing control behavior.
flutter test --no-pub --reporter expanded --concurrency=4
