#!/usr/bin/env bash
# usage: ./run_matrix.sh [timeout_s] [parallel] [names-file]   -- runs every config in matrix.txt (exhaustive TLC), summary in results/summary.txt
T=${1:-2700}; P=${2:-2}; LIST=${3:-matrix.txt}
cd "$(dirname "$0")"
one() { n=$1; T=$2; TLC_TIMEOUT=$T ./run_tlc.sh DifySF $n.cfg > /tmp/$n.out 2>&1; 
        printf "%-28s %s\n" "$n" "$(grep -E 'Error: (Invariant|Deadlock)|No error has been found|states generated|depth of|Finished in' /tmp/$n.out | tr '\n' ' ' | cut -c1-260)" >> results/summary.txt; }
export -f one
: > results/summary.txt
cat "$LIST" | xargs -P "$P" -I{} bash -c "one {} $T"
