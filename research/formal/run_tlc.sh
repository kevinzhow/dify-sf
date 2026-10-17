#!/usr/bin/env bash
# usage: ./run_tlc.sh <Spec> <cfgfile> [tlc extra args...]    (cfg path relative to tla/)
# Syncs tla/ + tools/tla2tools.jar to a JDK host (TLC_HOST, required unless TLC_LOCAL=1), runs TLC there, stores the log in
# results/. tools/tla2tools.jar is not in the repository: download it from https://github.com/tlaplus/tlaplus/releases.
# Local run (if `java` exists locally):  TLC_LOCAL=1 ./run_tlc.sh ...
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SPEC="$1"; CFG="$2"; shift 2
HOST="${TLC_HOST:-}"
if [ "${TLC_LOCAL:-0}" != 1 ] && [ -z "$HOST" ]; then echo "set TLC_HOST=<ssh host with java 21> or TLC_LOCAL=1" >&2; exit 2; fi
JAVA="${TLC_JAVA:-\$HOME/.jdks/jdk-21.0.12.1+1/bin/java}"
HEAP="${TLC_HEAP:--Xmx20g}"
WORKERS="${TLC_WORKERS:-8}"
LIMIT="${TLC_TIMEOUT:-3000}"   # seconds; the remote process is killed at the limit (no orphans)
OUT="$HERE/results/$(basename "$CFG" .cfg).log"
mkdir -p "$HERE/results"
if [ "${TLC_LOCAL:-0}" = 1 ]; then
  cd "$HERE/tla"; META=$(mktemp -d)
  java $HEAP -XX:+UseParallelGC -cp "$HERE/tools/tla2tools.jar" tlc2.TLC -workers "$WORKERS" -metadir "$META" -config "$CFG" "$@" "$SPEC" 2>&1 | tee "$OUT"
else
  JOB="dify-formal/jobs/$(basename "$CFG" .cfg)"
  ssh "$HOST" "mkdir -p ~/$JOB"
  rsync -aq --delete "$HERE/tla/" "$HOST:$JOB/"
  rsync -aq "$HERE/tools/tla2tools.jar" "$HOST:dify-formal/tla2tools.jar"
  ssh "$HOST" "cd ~/$JOB && mkdir -p ~/dify-formal/meta && META=\$(mktemp -d ~/dify-formal/meta/m.XXXX) && timeout $LIMIT $JAVA $HEAP -XX:+UseParallelGC -cp ~/dify-formal/tla2tools.jar tlc2.TLC -workers $WORKERS -metadir \$META -config $CFG $* $SPEC 2>&1; rm -rf \$META" | tee "$OUT"
fi
