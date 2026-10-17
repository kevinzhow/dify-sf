#!/bin/bash
# storm ladder: users x mixes x seeds. Output: out/storm/u<N>-<mix>[-f<focus>]-s<seed>.json
# env: USERS, MIXES, SEEDS, DUR (edit window, s), FOCUS (working-set size, default all 500 nodes), PAR, HEAP
cd "$(dirname "$0")/.."
export PATH=$PWD/.toolchain/node-v22.23.3-linux-x64/bin:$PATH
DUR=${DUR:-120}
TAG=""; FA=""
if [ -n "$CALIB" ]; then TAG="-cal"; FA="--rafdist out/rafdist_dom.json --panellag ${PANELLAG:-30}"; fi
if [ -n "$FOCUS" ]; then TAG="$TAG-f$FOCUS"; FA="$FA --focus $FOCUS"; fi
for seed in ${SEEDS:-1}; do for users in ${USERS:-10 25 50 100}; do for mix in ${MIXES:-disjoint contended faults}; do
  f=out/storm/u${users}-${mix}${TAG}-s${seed}.json
  [ -s $f ] && continue
  echo "NODE_OPTIONS=--max-old-space-size=${HEAP:-6000} npx tsx src/cli.ts storm --users $users --duration $DUR --mix $mix --seed $seed $FA --settle 50 --json --out $f > out/storm/u${users}-${mix}${TAG}-s${seed}.log 2>&1"
done; done; done | xargs -P ${PAR:-3} -I{} bash -c "{}"
