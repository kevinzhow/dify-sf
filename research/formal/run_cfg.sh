#!/usr/bin/env bash
# usage: ./run_cfg.sh <Spec> <cfg> [timeout_s] ; runs one TLC job, prints the summary lines
SPEC=$1; CFG=$2; T=${3:-1500}
TLC_TIMEOUT=$T ./run_tlc.sh $SPEC $CFG > /tmp/$(basename $CFG .cfg).out 2>&1
grep -E "Error|violated|Deadlock|states generated|Finished|depth of|No error" /tmp/$(basename $CFG .cfg).out | tail -6
