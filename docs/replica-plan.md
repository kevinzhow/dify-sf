# Replicating Dify's workflow editor in Flutter

The current cross-client/server delivery plan is [the migration plan on main](https://github.com/kevinzhow/dify-sf/blob/main/docs/migration-plan.md). This document retains the editor specification and historical acceptance outline. Font work is paused by the current direction. Full-site visual parity and Scene performance for the current Web default have not been accepted.

Goal: the Flutter client is Dify 1.17.1's workflow editor, look and behaviour, on the dify-sf collaborative document
and the Flutter canvas. Web defaults to the retained widget renderer on full Dart Wasm/skwasm; the Scene path remains available separately. Dify Web is the specification; deviations are recorded explicitly.

## Baseline

* Dify 1.17.1 source, inventoried into two checklists (every item cites its source file):
  * canvas, chrome and design tokens: 365 items (canvas 45, node chrome 52, edges 18, header 30, zoom/minimap/operator
    27, context menus 25, block selector 32, notes 15, comments 14, keyboard 25, auto-layout 7, history 6, panels 29,
    run/debug 17, variable inspect 11, tokens 12), with 220 colour tokens resolved to values;
  * nodes: about 1,370 items: registry and availability, the shared card (240 px wide, height follows content, 16 px
    handles near the top), every node type's card, panel sections, controls and validation (start, end, answer,
    template, code, LLM, knowledge retrieval, question classifier, parameter extractor, if-else, list operator,
    document extractor, HTTP, variable aggregator, assigner, iteration, loop, tool, agent, agent v2, human input,
    data source, knowledge base, triggers), and the shared panel widgets (variable picker, prompt editor with `/` and
    `{` insertion and `{{#node.var#}}` chips, code editor, forms, output variables, memory, vision, error handling,
    retry).
* Source quirks found while reading (likely Dify bugs) are listed in the inventories; we match Web behaviour unless
  Kevin decides otherwise.

## Acceptance

* Every checklist item is covered, partial, web-only or N/A, with evidence; the coverage report is generated, and a
  case existing is not a pass.
* Visual: Playwright opens the same workflow file (the 24 Dify samples plus large generated ones) in a local Dify
  1.17.1 and in our web build, same Chromium, viewport, scale, fonts and fake data; screenshots per page, component
  and state (hover, selected, dragging, panel open, error); `alignment-audit.py` (edge and text-line alignment) plus
  perceptual diff; keep full-region and tight control scores, including text. Same font/locale/viewport/state and geometry are required; a non-text score alone does not prove visual parity. The strict current control target is 99.5%, with actual failures retained; fonts remain deferred under the current pause. Passing shots may become golden baselines only for their stated scope.
* Dify's own unit tests: every case of Dify's vitest specs for the workflow editor, the model provider page and
  dify-ui (3823 cases) is ported to Dart with the same names, or listed as not applicable with a reason;
  `tool/dify_spec/ledger.py` reports the counts. A module counts as done when its Dify specs pass.
* Behaviour: interaction checklist per gesture and shortcut, scripted where possible; IME, real gestures and 120 Hz on
  real devices (mibook).
* Performance stays at the canvas spike's level (120 FPS at 2000 nodes on the test machine).

## Phases

1. **Foundations** (first, sequential): design tokens, typography and icons as Flutter tokens (pages use components,
   not raw values); canvas geometry like Dify (card width, handle positions, React Flow edge curve and colours, dotted
   background, zoom limits, wheel and trackpad behaviour); the visual-test harness and coverage report.
2. **Canvas and chrome**: node chrome and states, edges, zoom controls, minimap, operator bar, context menus,
   keyboard shortcuts, copy/paste/duplicate, undo/redo, auto-layout, notes, header bar.
3. **Node cards**: every node type's card (independent per node group, built in parallel).
4. **Shared panel widgets**: variable picker, prompt editor, code editor, forms, output variables, memory, vision,
   error handling, retry.
5. **Node panels**: every node type's panel with validation (in parallel per group), all edits as collaborative ops.
6. **Around the canvas**: block selector, run and debug panels, variable inspect, features, environment and
   conversation variables, publish and history UI. Panels that need data from Dify's backend (models, tools,
   knowledge bases, plugins) use fixtures recorded from the local Dify until dify-sf has those services; runs use a
   simulated engine until the runtime exists.
7. **Acceptance pass** and the real-device checks.

Each phase is pushed as it lands, with its part of the coverage report and visual results.
