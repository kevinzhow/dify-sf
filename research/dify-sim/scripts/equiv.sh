#!/bin/bash
# equivalence of performance layers: exact (no stubs/memo/lazy) vs memo vs memo+lazy, same seeds
cd "$(dirname "$0")/.."
export PATH=$PWD/.toolchain/node-v22.23.3-linux-x64/bin:$PATH
USERS=${USERS:-6}; DUR=${DUR:-15}
for seed in ${SEEDS:-1 2 3}; do for mix in disjoint contended faults; do for mode in off nolazy on; do
  echo "npx tsx src/cli.ts storm --users $USERS --duration $DUR --mix $mix --seed $seed --fast $mode --settle 40 --json --out out/equiv/u${USERS}-$mix-s$seed-$mode.json > /dev/null"
done; done; done | xargs -P ${PAR:-6} -I{} bash -c "{}"
