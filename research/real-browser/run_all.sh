#!/bin/bash
# Replays every browser scenario. Collab mode ON (default) first; then set ENABLE_COLLABORATION_MODE=false in
# dify-src/docker/.env, `docker compose up -d`, and run the second block with TAG=nocollab.
# ~2-3 h on an 8-core box (parallel=3).  Results: logs/<scenario>[-tag].jsonl ; table: .venv/bin/python summarize.py
cd "$(dirname "$0")"
PY=.venv/bin/python
P=${PARALLEL:-3}
run() { $PY -u scenarios.py "$1" --runs "$2" --parallel $P ${TAG:+--tag $TAG}; }

if [ "$MODE" != "nocollab" ]; then
  .venv/bin/python api_tests.py --runs 20
  run S1,S1L,S1N,S1NL,S1NR 20
  run S2,S2L,S2O,S2OS,S2OM,S2OL 20
  run S6A,S6B,S6C,S6D,S6E,S6F,S6G 20
  run S3A,S3B,S3C,S3D,S3E 20
  run S10 20
  run S4A,S4B,S4C 20
  run S4D 10
  run S5A,S5B,S5C,S5D 20
  run S7A,S7AL,S7B 20
  run S8,S9,S9X,S9Y 20
  run S9ZA,S9ZB,S9ZC 10
else
  # needs collab mode OFF on the server
  TAG=nocollab
  run S1,S1N,S2,S10,S3A,S3D,S5A,S6A,S6B,S6C,S6D,S6F,S8 20
fi
