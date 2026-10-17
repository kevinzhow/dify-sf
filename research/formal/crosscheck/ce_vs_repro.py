#!/usr/bin/env python3
"""Cross-check: every Dify counterexample (TLC, Dify.tla) vs the real-browser repro logs (repro/logs/*.jsonl).
Prints, per counterexample, which repro scenarios exhibit it (observed bad / valid runs) and flags the ones with no
real-browser observation.  usage: ce_vs_repro.py [repro_logs_dir]"""
import json, glob, os, sys, collections
LOGS = sys.argv[1] if len(sys.argv) > 1 else "research/real-browser/logs"

def stats(name):
    f = os.path.join(LOGS, name + ".jsonl")
    if not os.path.exists(f): return None
    recs = [json.loads(l) for l in open(f) if l.strip()]
    c = collections.Counter("+".join(r.get("verdict", ["?"])) for r in recs)
    valid = len(recs) - c.get("HARNESS_ERROR", 0)
    bad = valid - c.get("OK", 0)
    return bad, valid

# (counterexample id, model property, TLC config, repro scenarios that should show it, scenarios that must NOT show it (model says safe))
ROWS = [
 ("CE1 stale-view revert (same node, other field)", "P1/P5", "DF_P1_stale_view", ["S1N", "S1N-quiet", "S1NR"], ["S1NL", "S1", "S1L"],
  "S1NL (400 ms) must be safe: skip-if-equal makes network-concurrent whole-node writes harmless"),
 ("CE2 same field, concurrent (LWW)", "P2", "DF_P2_same_field", ["S2L"], [],
  "S2 (no latency) is labelled OK by the harness only because the loser's ack is read after it was overwritten; see analytic/NOTES.md 4"),
 ("CE3 object-valued list (code outputs)", "P1", "DF_P1_list_whole", ["S2O", "S2OL"], ["S2OM", "S2OS"],
  "windows: S2OM (0.8 s) / S2OS (3 s) safe"),
 ("CE4 index-synced Loro list (variables/prompt)", "P1", "DF_P1_list_index", [], [],
  "NO real-browser scenario yet (replay on real Loro only: formal/replay/replay_ce.py CE-D/CE-E)"),
 ("CE5 zombie node / delete vs concurrent edit", "P1/P2", "DF_P1_zombie", ["S7A", "S7AL"], [],
  "S7A/S7AL: delete vs concurrent rename + drag"),
 ("CE6 dangling reference after delete (sequential)", "P4", "DF_P4_dangling", ["S7B"], [],
  "S7B: single-user delete of a referenced node; code reading: use-nodes-interactions.ts handleNodeDelete does not rewrite references"),
 ("CE7 tab closes/crashes before the 5 s debounce", "P1", "DF_P1_tab_crash", ["S5A", "S5B", "S5C", "S5D", "S6C"], ["S6A", "S6B", "S6D", "S6E"],
  "graceful close / reload / navigation (S6A,B,D) flush OK; SIGKILL (S6C) loses; follower closes then leader dies (S5C) = permanent loss (model: DF_any_P1/P3/P5, 6 states)"),
 ("CE12 stale hash: new leader's first save fails (M9/M2)", "P1/P3", "DF_cov_stale_hash", ["S3C", "S3E"], [],
  "model: reachable state leader has unsaved edit and hash != store.hash (coverage probe, TLC trace in results/ces); the failed save is not retried"),
 ("CE8 websocket drop inside the debounce window", "P1", "DF_P1_disconnect", ["S4C"], ["S4A", "S4B"], ""),
 ("CE9 stale hash after leader hand-off / store lag", "P3/P1", "DF_P3_store_lag", ["S3C", "S3E"], ["S3A", "S3B"],
  "S3A/S3B (other tab hidden while someone edits) are safe in the repro; the model agrees (hide only hurts a tab that edited and hid inside the debounce window, CE11)"),
 ("CE11 edit, then hide the tab inside the 5 s debounce", "P1", "DF_P1_hide_after_edit", [], ["S3A", "S3B"],
  "NO repro scenario (S3D is adjacent: show -> 500 ms refresh cancels the pending debounce); code: canPersistLocalGraph() is false while hidden, the debounce is not re-armed"),
 ("CE10 relay restart loses unsaved edits", "P1", "DF_P1_relay_restart", [], [],
  "NO repro scenario (relay restart not injected); mechanism = same reload-from-draft path as CE8 (S4C)"),
]
NOT_MODELLED = [
 ("M2/S8 external write + 'swap hash only, keep canvas'", "S8 20/20, A2 20/20", "partly: SaveBy refreshes only the hash and never retries, but external (non-collab) writers are not modelled"),
 ("M12/S9* import / restore bypasses the CRDT", "S9 20/20, S9Y 20/20, S9ZC 20/20", "NOT modelled (new mechanism found by the repro, not by the formal model)"),
 ("M3/S6F,S6G keepalive 64 KB limit", "S6F 19/20", "NOT modelled (HTTP transport limit)"),
 ("M10/S4D leader blackholed: no retry of sync_request", "S4D 10/10", "partly: Fire fails without retry; undetected blackhole (no disconnect event) not modelled"),
 ("M13/A3,A4 features / variables saved without hash", "A3,A4 20/20", "NOT modelled (outside the graph)"),
 ("M14/A5 server has no referential integrity (empty graph, dangling edges)", "A5 20/20, S7B 20/20", "modelled: P4 (DF_P4_dangling)"),
]
print(f"{'counterexample':52} {'prop':6} {'repro scenarios exhibiting it (bad/valid)':48} {'scenarios the model says are safe (bad/valid)'}")
for name, prop, cfg, pos, neg, note in ROWS:
    def fmt(lst):
        out = []
        for s in lst:
            st = stats(s)
            out.append(f"{s} {st[0]}/{st[1]}" if st else f"{s} n/a")
        return ", ".join(out) or "-"
    flag = ""
    if not pos: flag = "  <-- no real-browser observation"
    elif all(stats(s) is None for s in pos): flag = "  <-- logs not available yet"
    elif not any((stats(s) or (0, 1))[0] > 0 for s in pos): flag = "  <-- repro did NOT show it (model/repro mismatch?)"
    if any((stats(s) or (0, 1))[0] > 0 for s in neg): flag += "  <-- repro shows loss where the model predicts safety"
    print(f"{name:52} {prop:6} {fmt(pos):48} {fmt(neg)}{flag}")
    if note: print(f"{'':52} note: {note}")

print()
print("Repro mechanisms (repro/REPORT.md) the formal model does NOT cover or covers only partly:")
for a, b, n in NOT_MODELLED: print(f"  - {a} | observed: {b} | model: {n}")
