#!/bin/bash
# Reproduce everything (virtual-time results only; calibration needs the local Dify + Playwright, see calib/).
# usage: scripts/run_all.sh [quick]
cd "$(dirname "$0")/.."
export PATH=$PWD/.toolchain/node-v22.23.3-linux-x64/bin:$PATH
K=${K:-60}
node build.mjs && node scripts/fidelity-table.mjs
node scripts/delta-equiv.mjs                                                         # wire-delta == whole-blob import (random concurrent docs)
npx tsx src/cli.ts sseries --runs $K --out out/sseries.json > out/sseries.txt        # ideal main thread
npx tsx src/cli.ts sseries --runs $((K*2)) --calib --out out/sseries-calib.json > out/sseries-calib.txt
npx tsx src/cli.ts catalog-yaml
npx tsx src/cli.ts catalog --runs ${KC:-30} > out/catalog-A.txt
python3 scripts/catalog_tables.py > out/catalog-summary.md
if [ "$1" != quick ]; then
  USERS="10 25" SEEDS=1 PAR=3 DUR=120 scripts/ladder.sh
  USERS="50" SEEDS=1 PAR=2 DUR=120 scripts/ladder.sh
  USERS="100" SEEDS=1 PAR=1 DUR=40 scripts/ladder.sh
  CALIB=1 FOCUS=40 MIXES="disjoint contended" USERS="10 25 50" DUR=60 PAR=3 scripts/ladder.sh
  CALIB=1 FOCUS=40 MIXES="disjoint contended" USERS="100" DUR=30 PAR=1 scripts/ladder.sh
fi
python3 scripts/storm_table.py > out/storm-table.md
