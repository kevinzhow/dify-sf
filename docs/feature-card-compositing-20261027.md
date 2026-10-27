# Shared feature-card compositing and title wrapping

FeatureCard painted its highlight over the entire outer container, then painted a translucent section background inside it. The pinned Dify 1.17.1 source only gives the card a top and left highlight border. The old layering made dark card interiors too bright.

The component now paints its background once and uses Flutter's existing top/left Border. Its spacing, radius, border width and colors come from DifyFeatureCardRecipe, generated from the pinned feature-card.tsx classes. Unsupported class changes fail generation; 15 source hashes protect the dependency. No color or font value was adjusted.

The same card also inherited DifyText's one-line default for its title. At a 320px window, “Citations and Attributions” was shortened with an ellipsis; Dify wraps it into two lines, which increases the header from the icon's 25px to two 16px lines. The shared string title now wraps naturally, preserving the following cards' positions.

The exact compositing regression passed in light mode and failed in dark mode before the border fix. A separate mounted regression failed because the narrow title exceeded its visible line count. Both pass after the changes; the title regression also checks multiple visible lines, card growth, switch operation and resizing back to the original width. The earliest screenshot test hung while waiting for asynchronous image IO in FakeAsync; that harness attempt is retained separately and is not a product failure.

Validation on the final product commit 187827dfac25c920f68cd6ca1d36f9896d83b66d: 384 relevant Flutter tests pass, analysis has no issues, all design/coverage guards and 15 source hashes pass, and the release Web Wasm build succeeds. The fonts and private engine inputs are unchanged. The new generator also rejects an unsupported padding-class mutation in a separate reference copy, without modifying the pinned source.

The browser driver is tool/visual/capture_feature_card_pages.py. It opens actual source and Flutter pages, blocks model execution, records source CSS and raw PNG hashes, then cleans up its own imported apps. It uses disposable sessions supplied as runtime input. Test credentials are neither source files nor report payloads.

## Acceptance scope

The original 450-scenario result remains historical at e84f90b: 171 strict, 67 basic, 212 different and no missing captures. Only the two existing Features scenarios and six supplemental page pairs are in this batch. Pixel and RGB scoring use the unchanged pinned Raft framework and raw provider PNGs. Diagnostic body samples use the original page's coordinates on both images, without alignment, masks, exclusions or threshold changes.

Android Chrome and iOS Safari physical-device tests remain pending. Browser window resizing is not physical-device certification. Native component painting is separate evidence from actual Web comparison. The trial API, data, uploads, keys, proxy, Agent/Shell services and HTTPS routing are outside this frontend-only change.

The final actual-page run passes all 12 geometry/interaction checks at 1440, 390 and 320px in both themes. All six original repeat images are byte-identical to the baseline. All 30 diagnostic points are retained: 15 light points have zero channel difference and 15 dark points have a remaining difference of one. The two points that previously landed in 320px layout gaps now sample the intended card bodies after the title wraps.

All eight scoped whole-image comparisons remain “different.” At 320px, light RGB similarity improves from 0.975544 to 0.989795 and dark from 0.965190 to 0.986895. These improvements do not certify complete page parity. The [full comparison and raw evidence](https://k17.tail4653d.ts.net/reports/feature-card-20261027/analysis.html) includes the unchanged metrics, intermediate border-only run and earlier failures; no full 450-scenario rerun is claimed.
