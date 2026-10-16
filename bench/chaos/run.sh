#!/usr/bin/env bash
# Chaos harness: N short randomised runs with real processes and injected faults (server kill -9, client kill -9 /
# pause in journaled and volatile modes, connection cuts and stalls, Postgres connection cuts, duplicate POSTs),
# each verified against the database and every client (I1-I6).
#
#   bench/chaos/run.sh 300        # 300 runs, 3 in parallel
#   PARALLEL=4 SEED=1000 bench/chaos/run.sh 100
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../run.sh" chaos --runs "${1:-20}" --seed "${SEED:-1}" --parallel "${PARALLEL:-3}" --out "/repo/bench/chaos/results/$(date +%Y%m%d-%H%M%S)"
