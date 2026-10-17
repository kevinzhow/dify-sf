#!/bin/bash
cd $(dirname $0)
PY=research/real-browser/.venv/bin/python
for cfg in "0 0 8" "40 0 5" "0 40 5"; do set -- $cfg
  $PY -u record.py s2o --fast --gap $1 --agap $2 --runs $3 --out data/s2o_fast.jsonl >> data/s2o_fast.log 2>&1
done
$PY -u record.py s2 --fast --lat 400 --runs 8 --out data/s2_lat400.jsonl >> data/s2_lat400.log 2>&1
