#!/usr/bin/env bash
# stop the Dify matrix driver and its running TLC job(s) (leaves the dify-sf matrix alone)
pkill -f "run_dify_matrix" 2>/dev/null
for j in $(ls "$(dirname "$0")"/../tla/DF_*.cfg | xargs -n1 basename | sed 's/.cfg//'); do pkill -f "run_tlc.sh Dify $j.cfg" 2>/dev/null; done
[ -n "${TLC_HOST:-}" ] && ssh -o ConnectTimeout=20 "$TLC_HOST" 'pkill -9 -f "config DF_" ; echo remote-dify-clean'
