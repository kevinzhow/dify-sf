#!/usr/bin/env bash
# usage: ./run_dify_matrix.sh [timeout_s] -- TLC on Dify.tla for every config in dify_matrix.txt (+ DF_any_*), shortest counterexample per config
T=${1:-1500}
cd "$(dirname "$0")"
mkdir -p results/ces
: > results/dify_summary.txt
for c in $(cat dify_matrix.txt); do
  TLC_TIMEOUT=$T ./run_tlc.sh Dify $c.cfg > /tmp/$c.out 2>&1
  printf "%-22s %s\n" "$c" "$(grep -E 'Error: Inv|Deadlock|No error has been found|states generated|depth of|exception' /tmp/$c.out | tr '\n' ' ' | cut -c1-240)" >> results/dify_summary.txt
  python3 tools/trace_summary.py results/$c.log --model dify > results/ces/$c.txt 2>&1
done
