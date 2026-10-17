# Dify 1.17.1 vs dify-sf: does collaborative editing lose work?

Four independent sources, each answering the same question:

* **Real browser**: real Dify 1.17.1, real Chromium tabs driven by Playwright, 20 runs per scenario.
* **Code-level simulator**: Dify's own collaboration and save code (collaboration manager, panel write-back, Loro WASM,
  the relay and draft API) loaded unchanged into one process, with browser, network, timers and tab visibility replaced
  by a virtual clock. Calibrated against the real-browser runs (link latency, main-thread latency measured in Chromium).
* **Formula**: a closed-form loss model of Dify's mechanisms (same-register last-writer-wins, stale whole-node write-back,
  per-index list sync, delete vs. edit, persistence), checked against a mechanism-level Monte Carlo and real Loro.
* **dify-sf**: this repository (protocol 1.4): the deterministic simulator, the real server with real client processes
  under a fault proxy, and the same conflict catalog.

Loss means: an edit the user saw accepted is not in the final state, or was overwritten by someone who never saw it,
**without the user being told**. dify-sf refuses the later of two conflicting writes and tells its author (with who wrote
the newer value); that is a conflict notice, not a loss.

## 1. Two-person scenarios

| scenario | real browser | simulator (calibrated) | formula | dify-sf |
|---|---|---|---|---|
| different nodes (S1) | 0/20 | 0/60 | 0 | 0 |
| same node, different fields (S1N) | 3/20 (15%) | 17% [9-28%] ¹ | 16% | 0, both kept |
| same, +400 ms latency (S1NL) | 0/20 | 1/60 | 0% | 0, both kept |
| same, main thread slowed 250 ms (S1NR) | 12/20 (60%) | 90% [80-95%] ² | 54% (fitted) | 0, both kept |
| same title, concurrent (S2) | one title silently dropped every run ³ | 120/120 | 89% | 0 silent; the later write is refused with a notice |
| same title, +400 ms (S2L) | 20/20 | 120/120 | 100% | 0 silent; refused with a notice |
| each adds a different output variable (S2O) | 19/19 | per-run replay agrees with the real outcome in 38/40 runs ⁴ | 87% | 0, both kept |
| same, +400 ms (S2OL) | 20/20 | 92% | 100% | 0, both kept |
| same, second user 0.8 s later (S2OM) | 0/20 | 10% | 0% | 0 |
| same, second user 3 s later (S2OS) | 0/20 | 0/120 | 0% | 0 |
| leader tab closes or crashes while others are online, stale version after leader hand-off, 8 s offline, silent leader drop, closing a 100-node graph (64 KiB keepalive limit), external write or import then save | 20/20 lost in most (see the real-browser report) | lost in every run | (deterministic, not a rate) | 0 in the matching scenarios, 330-run chaos and 38 storm rounds |

¹ Driven by the commit-time differences of the same real runs; with the calibration recordings' timing it was 26%.
² Known gap: the real runs slow the main thread with a JavaScript hack; the simulator models it as a fixed delay.
³ The real-browser harness labelled S2 "OK" because the loser's tab already showed the winner when the acknowledgement
was read; in every run exactly one of two different titles survived (formula analysis of the same logs).
⁴ Each recorded run's four commit times replayed: 21/23 and 17/17 runs give the same outcome as the real browser
(real 19/23 and 17/17 lost; simulator 73% and 99%). Earlier the simulator sampled the start offset and the add-rename gap
independently, which lost their correlation (53%).

## 2. Load: N users editing a 500-node workflow

Workload of the formula: every user edits every 10 s on average (Poisson); half of the edits go to 30 hot nodes, typed
40/30/30 as same field / same node different fields / list append; the other half to fields only that user writes.
Simulator: Dify's code with exactly this workload, calibrated main thread, several seeds per point; losses counted with
the formula's own definition (an edit is lost if it is not on the final value's chain of "who saw whom").

| users | one-way latency | simulator (Dify code) | 95% CI | formula | simulator / formula | edits in every replica but not yet saved 40 s after the last edit |
|---|---|---|---|---|---|---|
| 10 | 400 ms | 0.33% | 0.17-0.57% | 0.28% | 1.18 | 0% |
| 10 | 2 s | 0.88% | 0.50-1.42% | 1.17% | 0.75 | 19% |
| 25 | 400 ms | 0.66% | 0.41-1.03% | 0.73% | 0.91 | 9% |
| 25 | 2 s | 2.38% | 1.67-3.28% | 2.86% | 0.83 | 29% |
| 50 | 400 ms | 1.69% | 1.13-2.44% | 1.45% | 1.17 | 25% |
| 50 | 2 s | 4.66% | 3.70-5.79% | 5.11% | 0.91 | 36% |
| 100 | 400 ms | not run ⁵ | | 2.8% | | |
| 100 | 2 s | not run ⁵ | | 8.3% | | |

All six simulated points fall inside their 95% intervals; pooled, 189 losses observed against 205 predicted (0.92).
A two-user sweep confirms the window directly: at 2 s one-way latency two writes to the same title lose one of them
exactly when they are less than ~4.1 s apart (2 x latency + view lag), never at 4.5 s.

⁵ 100 tabs on a 500-node graph run about 124 times slower than real time in the simulator (and need >3 GB); the formula,
validated at 10-50 users, gives the 100-user numbers.

**A second Dify problem at scale: saving falls behind.** Only one tab (the leader) saves the shared draft. In a 400-s
run with 50 users at 400 ms the leader's view lagged: the median edit took 186 s to reach the database, and 1187 of 1204
snapshot requests timed out. The table's last column counts edits that every open tab has but the database does not, 40 s after the last edit.
They are saved eventually if tabs stay open; if everyone closes the page in that window they are gone.

**dify-sf under load** (docs/results/storm-100c-sweeps.md): 100 clients, 500 nodes, 19 network profiles, with and without
process faults (client kill, server kill -9 every 25-40 s): 38/38 rounds, about 365 000 edits, 0 confirmed edits lost, 0
silent overwrites, 0 divergence, 0 dangling references. Its workload is harsher on purpose (30% of edits write different
values to shared fields), so its conflict-notice counts (about 24% of edits at +2 s round trip) are not a loss rate to set
against Dify's: they are the edits Dify would have overwritten silently, told to their authors instead. Each change is
on the database before it is acknowledged, so nothing waits for a leader to save.

## 3. Conflict catalog, tier A (88 cases, same ids on both sides)

docs/results/scorecard-A.md: **Dify has a loss in 33 of 88 cases (calibrated simulator, 30 runs each); dify-sf in 0 of 88
(20 runs each)**. By relation: same field 12/14 vs 0, same node different fields 7/14 vs 0, overlapping paths 2/4 vs 0,
same list different items 7/14 vs 0, different nodes 0/18 vs 0, references 2/8 vs 0, structure 3/16 vs 0. Running the
catalog found one hole in dify-sf (a reference to a removed output variable); protocol 1.4 closed it.

## 4. Limits

* Real-browser numbers exist only for two-person scenarios; at 10-100 users Dify is represented by the simulator and the
  formula, which agree with each other and, where both exist, with the real browser.
* The simulator's main-thread latency comes from one calibration session on one machine; slower machines widen every
  window.
* The persistence column depends on the 40 s quiet period chosen at the end of each run; it shows a lag, not a fixed loss.
* dify-sf's load results come from its own storm workload, not from Dify's UI; the two systems are compared on outcomes
  (lost, silently overwritten, told), not on identical keystrokes.
