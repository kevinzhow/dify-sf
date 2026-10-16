#!/usr/bin/env bash
# Storm benchmark. One command per scenario; results land in bench/storm/results/<timestamp>/ (JSON + markdown).
#
#   bench/storm/run.sh mix-a          100 clients, disjoint edits only
#   bench/storm/run.sh mix-b          100 clients, 40% disjoint / 30% same value / 30% different values
#   bench/storm/run.sh mix-c          mix b + connection drops, client kills, duplicate POSTs, server kill -9
#   bench/storm/run.sh ladder [a|b|c] 10 -> 25 -> 50 -> 100 clients (default mix b)
#   bench/storm/run.sh sweep          every network profile (docs/step1-report.md), 25 clients, mix b
#   bench/storm/run.sh profile NAME   mix b under one network profile
#
# DURATION (seconds, default 120) and CLIENTS (default 100) can be overridden through the environment.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="/repo/bench/storm/results/$(date +%Y%m%d-%H%M%S)"
dur="${DURATION:-120}"
n="${CLIENTS:-100}"
case "${1:-}" in
  mix-a|mix-b|mix-c) exec "$here/../run.sh" storm --mix "${1#mix-}" --clients "$n" --duration "$dur" --out "$out" ;;
  ladder) exec "$here/../run.sh" storm --ladder --mix "${2:-b}" --duration "$dur" --out "$out" ;;
  sweep) exec "$here/../run.sh" storm --sweep --clients "${CLIENTS:-25}" --duration "${DURATION:-60}" --out "$out" ;;
  profile) exec "$here/../run.sh" storm --mix b --clients "${CLIENTS:-25}" --duration "${DURATION:-60}" --profile "${2:?profile name}" --out "$out" ;;
  *) sed -n 2,12p "$0"; exit 2 ;;
esac
