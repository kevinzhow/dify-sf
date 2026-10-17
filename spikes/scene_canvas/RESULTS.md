# Canvas spike: Flutter Scene vs widgets, Linux desktop, 120 Hz target

Question: can the workflow canvas reach 120 FPS on Linux at 500 to 2000 nodes, and does Flutter Scene help?
Same graph generator as `app/integration_test/canvas_perf_test.dart` (25-wide grid, chain plus a fan-out every 7 nodes).

## Three canvases, one script

| mode | cards | edges | pan/zoom |
|---|---|---|---|
| `widgets` | widgets, only those in the viewport are built, a RepaintBoundary each | one cached picture (`CustomPaint`) | one layer transform |
| `scene` | `WidgetComponent` per node (Flutter Scene), captured once and again only when the card changes | one GPU-expanded `LineSegmentsGeometry` batch | orthographic camera |
| `hybrid` | widgets, as in `widgets` | Flutter Scene layer under the cards, as in `scene` | both follow the same view |

The script (`lib/main.dart`, `BENCH=true`) runs 4 s per phase: pan (diagonal sweep), zoom (0.4x to 1.6x), edits
(another user renames visible nodes, 20/s; scene mode recaptures those cards), drag (one node in a circle; only its
edges are rebuilt per frame). Then it zooms to 2x and makes text crisp (scene: recapture visible cards at 2x density).
Frame timings come from `FrameTiming`; the interval is the time between consecutive raster finishes.

## Environment

* Headless Weston 14 with the GL renderer on the real GPU (Intel Lunar Lake iGPU), virtual output at 120 Hz;
  `tool/bench.sh` starts it, runs one configuration, takes a compositor screenshot (`SHOOT_AT`), stops it.
* Flutter 3.47.6, profile build, Impeller (OpenGL ES), Flutter GPU on; frames released on the GTK frame clock by the
  vsync driver from raft-flutter (the stock GTK embedder paces at a fixed 60 Hz).
* The empty scene sets the floor this setup can reach: at 1x its p99 interval is already about 11 ms, at 2x it does
  not reach 120 FPS at all (GTK and the compositor copy 4x the pixels). The 9.6 ms p99 acceptance check therefore
  needs a real 120 Hz screen; here the comparison between canvases is what counts.

## Results

Each cell: frames per second and the p99 frame interval in ms (120 Hz = 8.3 ms). Raw output in `results/`.

| 1x (1600x1000) | pan | zoom | edits 20/s | drag | load ms | RSS MB |
|---|---|---|---|---|---|---|
| empty scene (floor) | 122 fps, p99 11.3 | 121 fps, p99 10.7 | 118 fps, p99 11.0 | 119 fps, p99 10.6 | - | - |
| widgets 500 | 116 fps, p99 15.3 | 119 fps, p99 17.3 | 121 fps, p99 12.2 | 119 fps, p99 12.0 | 113 | 213 |
| widgets 1000 | 116 fps, p99 14.5 | 116 fps, p99 15.3 | 120 fps, p99 11.4 | 122 fps, p99 11.5 | 118 | 224 |
| widgets 2000 | 115 fps, p99 14.6 | 118 fps, p99 16.6 | 119 fps, p99 11.7 | 119 fps, p99 12.1 | 119 | 221 |
| scene 500 | 119 fps, p99 14.3 | 120 fps, p99 10.4 | 118 fps, p99 11.0 | 120 fps, p99 11.7 | 339 | 258 |
| scene 1000 | 116 fps, p99 14.2 | 118 fps, p99 10.7 | 118 fps, p99 11.2 | 119 fps, p99 10.4 | 554 | 317 |
| scene 2000 | 120 fps, p99 11.3 | 122 fps, p99 11.1 | 118 fps, p99 10.5 | 120 fps, p99 11.4 | 1014 | 409 |
| hybrid 500 | 115 fps, p99 16.2 | 116 fps, p99 17.1 | 119 fps, p99 11.0 | 120 fps, p99 11.2 | 113 | 215 |
| hybrid 1000 | 120 fps, p99 13.6 | 120 fps, p99 14.3 | 122 fps, p99 11.4 | 118 fps, p99 11.5 | 120 | 217 |
| hybrid 2000 | 115 fps, p99 16.3 | 119 fps, p99 17.4 | 121 fps, p99 11.7 | 120 fps, p99 11.1 | 114 | 220 |
| scene 500, card semantics on | 58 fps, p99 18.7 | 58 fps, p99 18.3 | 101 fps, p99 19.6 | 62 fps, p99 18.4 | 329 | 250 |

| 2x (3200x2000) | pan | zoom | edits 20/s | drag | load ms | RSS MB |
|---|---|---|---|---|---|---|
| empty scene (floor) | 101 fps, p99 21.8 | 106 fps, p99 16.6 | 102 fps, p99 16.8 | 109 fps, p99 16.5 | - | - |
| widgets 500 | 106 fps, p99 22.1 | 110 fps, p99 20.4 | 117 fps, p99 16.0 | 117 fps, p99 16.2 | 114 | 258 |
| widgets 2000 | 107 fps, p99 22.7 | 101 fps, p99 22.5 | 120 fps, p99 13.7 | 113 fps, p99 16.1 | 135 | 261 |
| scene 500 | 102 fps, p99 22.4 | 116 fps, p99 14.4 | 120 fps, p99 13.6 | 122 fps, p99 12.6 | 342 | 279 |
| scene 2000 | 10 fps, p99 289.6 | 72 fps, p99 79.4 | 90 fps, p99 26.3 | 85 fps, p99 23.5 | 2560 | 432 |
| hybrid 500 | 108 fps, p99 22.3 | 114 fps, p99 17.7 | 119 fps, p99 14.1 | 119 fps, p99 13.9 | 120 | 268 |
| hybrid 2000 | 105 fps, p99 22.4 | 112 fps, p99 22.3 | 118 fps, p99 15.5 | 119 fps, p99 14.0 | 115 | 264 |

## Findings

1. **All three canvases hold about 120 FPS at 1x up to 2000 nodes.** The app's current canvas (rebuilding the
   positioned cards every frame) was build-bound at 1000 and 2000 nodes (`docs/results/canvas-perf.md`); viewport
   culling plus one layer transform is enough to fix that, with or without Flutter Scene.
2. **Semantics decides whether Flutter Scene works.** The GTK embedder keeps the semantics tree on, and `SceneView`
   updates every hosted card's semantics each frame. With 500 cards about 90% of the UI thread went to
   `_RenderObjectSemantics` (Dart CPU profile, `tool/vmprof.dart`) and the canvas ran at 58 FPS. The cost grows
   faster than the card count and does not depend on what is on screen. Wrapping
   the cards in `ExcludeSemantics` removes the cost; a scene canvas then has to expose its own per-node summary to
   screen readers.
3. **Flutter Scene is smoother on zoom at 1x** (p99 10.4 to 11.1 ms, at the floor) because nothing is built while the
   view changes. The widget canvases build cards that come into view, which shows as zoom/pan p99 of 13.6 to 17.4 ms.
4. **Flutter Scene's cost is memory and texture density.** One texture per card: load 3x to 9x slower, 45 to 190 MB
   more memory at 1x. At 2x density with 2000 cards panning collapsed to 10 FPS (raster p99 290 ms) while the widget
   canvases stayed at the floor. Text is a capture: zooming in shows blurry cards until they are recaptured (22 to
   80 ms for the visible cards). A shipping version needs texture budgeting (only cards near the view keep a texture,
   an atlas, lower density when zoomed out).
5. **Two `WidgetComponent` details:** its default quad is front-facing toward -Z but maps the texture as seen from
   +Z, so cards render mirrored (fixed with an own quad with flipped u); and a manual-capture card must be recaptured
   after it repaints (done from a post-frame callback).
6. **The hybrid costs nothing over widgets** and keeps everything widgets give (semantics, pointer and keyboard input,
   text at screen resolution), while edges, background and future shader or 3D effects live in a Flutter Scene layer.

## Recommendation

* Canvas now: culled widget cards with one layer transform (as in `widgets`/`hybrid`), plus building cards ahead of
  the viewport edge to remove the zoom/pan build spikes.
* Flutter Scene as the layer under the cards (hybrid): edges first, then background and effects. Cards inside the
  scene only once texture budgeting and accessibility are solved.
* Final 120 Hz acceptance on a real 120 Hz screen.

Not covered yet: pointer and keyboard input on scene cards (`WidgetInput.automatic`), text input inside cards, the
web build (the bench entry point uses `dart:io`).

## Running

```
flutter build linux --profile
MODE=scene NODES=2000 SEM=0 tool/bench.sh build/linux/x64/profile/bundle/scene_canvas results/full-scene-2000.log
python3 tool/table.py results
```

Switches (environment): `MODE`, `NODES`, `SEM=0` (cards out of the semantics tree), `EDGES=0`, `CARDS=0`, `AA`,
`PHASES`, `POLICY=every`, `HOME_VIEW=x,y,scale`; bench: `W`, `H`, `SCALE`, `SHOOT_AT`.
