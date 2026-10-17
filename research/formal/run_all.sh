#!/usr/bin/env bash
# Reproduce everything (about 2-3 hours on a 16-core host; steps 3-4 dominate).  See REPORT.md section 8.
set -e
cd "$(dirname "$0")"
PY=.venv/bin/python
echo "== 0. environment";  [ -x $PY ] || { uv venv .venv -q && uv pip install -q --python $PY matplotlib numpy scipy loro; }
[ -f tools/tla2tools.jar ] || curl -sSL -o tools/tla2tools.jar https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
echo "== 1. Loro semantics the models rely on (real Loro)";  $PY loro-check/loro_semantics.py
echo "== 2. generate TLC configs";  python3 gen_cfgs.py > /dev/null
echo "== 3. Dify: shortest counterexamples (TLC)";       ./run_dify_matrix.sh 1500; cat results/dify_summary.txt
echo "== 4. dify-sf: exhaustive runs + mutants (TLC)";   ./run_matrix.sh 2700 2; cat results/summary.txt
for m in $(ls tla/SFmut_*.cfg | xargs -n1 basename | sed 's/.cfg//'); do ./run_cfg.sh DifySF $m.cfg 300 | grep -E "Error: (Inv|Dead)|No error" | head -1 | sed "s/^/$m: /"; done
echo "== 5. replay Dify counterexamples on real Loro";   $PY replay/replay_ce.py
echo "== 6. counterexamples vs real-browser logs";       python3 crosscheck/ce_vs_repro.py
echo "== 7. analytic loss model (quick checks; full grid: see analytic/NOTES.md)"
(cd analytic && $PWD/../$PY model.py | head -20 && $PWD/../$PY validate_vs_loro.py 500 && $PWD/../$PY calibration.py | tail -15 && $PWD/../$PY make_plots.py)
