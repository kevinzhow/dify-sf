#!/usr/bin/env bash
# usage: ./run_long.sh <timeout_s> <workers> cfg...   -- re-run (in parallel) the configurations that hit the time limit in run_matrix.sh
T=$1; W=$2; shift 2
cd "$(dirname "$0")"
for c in "$@"; do
  ( TLC_WORKERS=$W TLC_TIMEOUT=$T ./run_tlc.sh DifySF $c.cfg > /tmp/$c.long.out 2>&1
    cp results/$c.log results/long/$c.log
    printf "%-22s %s\n" "$c" "$(grep -E 'Error: Inv|Deadlock|No error has been found|states generated|depth of|Finished in' /tmp/$c.long.out | tr '\n' ' ' | cut -c1-260)" >> results/long_summary.txt ) &
done
wait
