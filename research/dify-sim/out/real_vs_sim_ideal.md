| scenario | what (Dify 1.17.1) | real browsers: verdicts | real loss-like | sim, ideal main thread | sim, harness-calibrated | sim/real overlap (calibrated) | sim M2 (silent LWW overwrite) cal |
|---|---|---|---|---|---|---|---|
| S1 | A: rename c1 + drag c2; B: rename c3 + drag c4 (different nodes) | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S1L | S1 with 400 ms one-way websocket latency | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S1N | A edits c1.title, B edits c1.desc (same node, different fields) | {'OK': 17, 'LOST_EDIT': 3} | 3/20 [5-36%] | 15/60 [16-37%] | 28/120 [17-32%] | yes | 0/120 |
| S1NL | S1N with 400 ms websocket latency | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 3/120 [1-7%] | yes | 0/120 |
| S1NR | S1N with 250 ms rAF delay on both tabs (busy main thread) | {'LOST_EDIT': 12, 'OK': 8} | 12/20 [39-78%] | 46/60 [65-86%] | 32/120 [20-35%] | **NO** | 0/120 |
| S2 | A and B rename the same node title concurrently | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 120/120 |
| S2L | S2 with 400 ms latency | {'OK+LWW_ONE_EDIT_DROPPED': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 120/120 |
| S2O | A and B each add a different output variable to code node c2 | {'LOST_EDIT': 19} | 19/19 [83-100%] | 42/60 [57-80%] | 62/120 [43-60%] | **NO** | 0/120 |
| S2OL | S2O with 400 ms latency | {'LOST_EDIT': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 109/120 [84-95%] | yes | 0/120 |
| S2OS | S2O but B starts 3 s after A (control) | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S2OM | S2O but B starts 0.8 s after A | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 28/120 [17-32%] | **NO** | 0/120 |
| S3A | B hidden while leader A edits+saves; B returns and edits c3 | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S3B | leader A hidden while B edits; A returns | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S3C | stale hash after leader hand-off: A(leader),B,C; A edits+saves, A clos | {'DIVERGENCE+LOST_EDIT+PERMANENT_LOSS': 20} | 20/20 [84-100%] | 59/60 [91-100%] | 59/120 [40-58%] | **NO** | 0/120 |
| S4A | follower B loses websocket for 12 s while A edits; B reconnects, then  | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S4B | B edits (focus already in title field) AFTER its websocket dropped; th | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S4C | single user A: edit, websocket drops 1.5 s later (inside debounce), re | {'LOST_EDIT': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S4D | leader A drops silently (blackhole) for 60 s right after B edits; B sh | {'LOST_EDIT+DIVERGENCE': 10} | 10/10 [72-100%] | 60/60 [94-100%] | 71/120 [50-68%] | **NO** | 0/120 |
| S5A | leader A edits then closes the tab gracefully 0.5 s later | {'LOST_EDIT+DIVERGENCE': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S5B | leader A edits then crashes 0.5 s later; B stays open | {'LOST_EDIT+DIVERGENCE': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S5C | FOLLOWER B edits and closes 0.5 s later; leader A idle (then crashes l | {'LOST_EDIT+DIVERGENCE': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S5D | single user: edit, crash 0.5 s later | {'LOST_EDIT': 19, 'OK': 1} | 19/20 [76-99%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S6A | single user: 4 quick edits then close after 0.3 s | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S6B | single user: 4 quick edits then reload after 0.3 s | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S6C | single user: 4 quick edits then crash after 0.3 s | {'LOST_EDIT': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S6D | single user: 4 quick edits then nav after 0.3 s | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S6E | single user: 4 quick edits then wait after 0.3 s | {'OK': 20} | 0/20 [0-16%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S6F | single user, LARGE workflow (80 code nodes, >64 KB JSON): edit one tit | {'LOST_EDIT': 19, 'OK': 1} | 19/20 [76-99%] | 0/60 [0-6%] | 0/120 [0-3%] | **NO** | 0/120 |
| S6G | single user, small workflow (4 nodes): same as S6F (control) | {'OK': 18, 'LOST_EDIT': 2} | 2/20 [3-30%] | 0/60 [0-6%] | 0/120 [0-3%] | yes | 0/120 |
| S7A | A deletes c2 while B renames c2 and drags c3 | {'LOST_EDIT+DIVERGENCE+BROKEN_REFERENCE': 1, 'LOST_EDIT+BROKEN_REFERENCE': 8, 'OK+DELETE_REVERTED': 4, 'LOST_EDIT+PEER_MISSING+DELETE_REVERTED': 1, 'OK+BROKEN_REFERENCE': 1} | 15/15 [80-100%] | 50/60 [72-91%] | 120/120 [97-100%] | yes | 0/120 |
| S7AL | S7A with 400 ms latency | {'LOST_EDIT+BROKEN_REFERENCE': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S7B | single user baseline: delete c4 (end node references it) | {'OK+BROKEN_REFERENCE': 20} | 20/20 [84-100%] | 0/60 [0-6%] | 0/120 [0-3%] | **NO** | 0/120 |
| S8 | draft changed out-of-band (API) while leader tab open; tab then makes  | {'LOST_EDIT': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |
| S9 | DSL import (workflow_update broadcast) while B has an edit inside its  | {'LOST_EDIT+DIVERGENCE': 20} | 20/20 [84-100%] | 60/60 [94-100%] | 120/120 [97-100%] | yes | 0/120 |

calibrated-sim vs real, scenarios with real data: 27/34 have overlapping 95% Wilson intervals
