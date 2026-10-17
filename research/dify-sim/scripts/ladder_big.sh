#!/bin/bash
cd "$(dirname "$0")/.."
USERS="50" SEEDS=1 PAR=2 DUR=120 ./scripts/ladder.sh
USERS="100" SEEDS=1 PAR=1 DUR=40 ./scripts/ladder.sh
CALIB=1 FOCUS=40 MIXES="disjoint contended" USERS="10 25" DUR=60 PAR=2 ./scripts/ladder.sh
CALIB=1 FOCUS=40 MIXES="disjoint contended" USERS="50" DUR=60 PAR=2 ./scripts/ladder.sh
CALIB=1 FOCUS=40 MIXES="disjoint contended" USERS="100" DUR=30 PAR=1 ./scripts/ladder.sh
