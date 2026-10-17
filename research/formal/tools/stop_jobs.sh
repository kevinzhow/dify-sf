#!/usr/bin/env bash
# stop every local driver script and all remote TLC processes of this project
for p in run_matrix.sh run_dify_matrix.sh run_dify_some.sh run_cfg.sh run_tlc.sh; do pkill -f "$p" 2>/dev/null; done
pkill xargs 2>/dev/null
[ -n "${TLC_HOST:-}" ] && ssh -o ConnectTimeout=20 "$TLC_HOST" 'pkill -9 -f "[t]lc2.TLC"; rm -rf /tmp/tlcmeta.*; echo remote-clean'
