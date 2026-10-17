# Canvas performance (Linux desktop, profile build, virtual display 1600x1000)

`app/integration_test/canvas_perf_test.dart` (run command in its header; `--dart-define=NODES=N`). Each interaction is
measured with `watchPerformance`: build and raster time per frame, frames over the 16.7 ms budget (60 Hz).

| nodes | interaction | build avg / p90 / p99 ms | raster p99 ms | frames over budget |
|---|---|---|---|---|
| 500, before | pan | 18.2 / 30.9 / 34.4 | 7.2 | 159/226 |
| 500, before | zoom (buttons) | 14.2 / 24.0 / 26.4 | 4.7 | 39/88 |
| 500, before | drag a node | 5.8 / 26.4 / 35.1 | 5.4 | 36/162 |
| 500, before | another user edits titles, 20/s | 25.3 / 28.6 / 45.2 | 5.6 | 99/100 |
| 500, card cache | pan | 5.5 / 9.2 / 16.0 | 5.6 | 3/233 |
| 500, card cache | zoom (buttons) | 8.4 / 10.5 / 11.3 | 4.8 | 0/87 |
| 500, card cache | drag a node | 1.6 / 8.7 / 9.2 | 4.3 | 0/181 |
| 500, card cache | another user edits titles, 20/s | 9.1 / 9.3 / 14.3 | 4.6 | 0/100 |
| 1000, card cache | pan | 11.9 / 20.5 / 26.0 | 6.3 | 90/241 |
| 1000, card cache | zoom (buttons) | 16.7 / 20.3 / 25.2 | 5.2 | 51/88 |
| 1000, card cache | drag a node | 3.6 / 15.3 / 24.5 | 5.5 | 7/180 |
| 1000, card cache | another user edits titles, 20/s | 16.6 / 20.1 / 21.5 | 5.8 | 95/100 |
| 2000, card cache | pan | 27.2 / 43.2 / 49.7 | 6.4 | 176/219 |
| 2000, card cache | zoom (buttons) | 33.6 / 43.6 / 46.8 | 5.5 | 86/86 |
| 2000, card cache | drag a node | 14.2 / 45.0 / 47.6 | 5.4 | 63/181 |
| 2000, card cache | another user edits titles, 20/s | 41.0 / 46.6 / 58.6 | 5.3 | 100/100 |

| nodes | edges | load ms | memory loaded / end MB |
|---|---|---|---|
| 500 (before) | 567 | 425 | 273 / 302 |
| 500 | 567 | 385 | 272 / 286 |
| 1000 | 1139 | 513 | 341 / 347 |
| 2000 | 2282 | 778 | 456 / 494 |

Before: every frame rebuilt all node cards. Now cards are cached per node (reused while the node instance, its selection
and hover are unchanged), so panning, zooming and edits to other nodes rebuild only the position wrappers. 500 nodes now
stay within budget except 3 pan frames; at 1000 and 2000 nodes the remaining cost is building 1000-2000 position
wrappers per frame (raster stays at 5-6 ms): next steps are building only visible nodes and panning one transformed
layer instead of repositioning every card. For comparison, Dify's editor needed about 1.2 GB per Chromium tab for a
500-node workflow.
