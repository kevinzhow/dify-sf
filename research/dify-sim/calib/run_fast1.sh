#!/bin/bash
cd $(dirname $0)
PY=research/real-browser/.venv/bin/python
for cfg in "0 0 10" "30 0 6" "0 30 6" "80 0 4" "0 80 4"; do set -- $cfg
  $PY -u record.py s1n --fast --gap $1 --agap $2 --runs $3 --out data/s1n_fast.jsonl >> data/s1n_fast.log 2>&1
done
