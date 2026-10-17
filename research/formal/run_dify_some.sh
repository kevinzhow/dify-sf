#!/usr/bin/env bash
# usage: ./run_dify_some.sh <timeout_s> cfg1 cfg2 ...   (Dify counterexample hunt for selected configs)
T=$1; shift
cd "$(dirname "$0")"; mkdir -p results/ces
for c in "$@"; do
  TLC_TIMEOUT=$T ./run_tlc.sh Dify $c.cfg > /tmp/$c.out 2>&1
  printf "%-22s %s\n" "$c" "$(grep -E 'Error: Inv|Deadlock|No error has been found|states generated|depth of|exception' /tmp/$c.out | tr '\n' ' ' | cut -c1-240)" >> results/dify_summary2.txt
  python3 tools/trace_summary.py results/$c.log --model dify > results/ces/$c.txt 2>&1
done
