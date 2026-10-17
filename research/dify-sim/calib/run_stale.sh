#!/bin/bash
cd $(dirname $0)
PY=research/real-browser/.venv/bin/python
for g in 2000 8000; do
  $PY -u record.py s2o_stale --gap $g --runs 6 --out data/s2o_stale_$g.jsonl >> data/s2o_stale.log 2>&1
done
