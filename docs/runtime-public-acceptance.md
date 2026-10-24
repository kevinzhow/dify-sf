# Published runtime acceptance — 2026-10-24

Published workflow/Chatflow execution, separate end-user ownership, files/forms, durable recovery and operational
records are implemented. The final frontend source is `c4f19278c239a366a2dc93d1f85456b5dc9ae209`; the server source is
`2e44322bdd0d94a0a9a3fdf15fee2d9c06ad9383`. Later acceptance-script/documentation commits do not change those product
trees. The server image is `sha256:c37f1f5e64b72062ed91d47fc8535b3f5c0b014fac3df8e5946fe11e356b03a9`.

The final standalone WebAssembly build took 247.0 seconds with Flutter 3.47.6. Its 1,598 files are frozen at
`/var/tmp/Winnie/previews/public-c4f1927`; main Wasm SHA-256 is
`983ecbeb921ba9c29fd19ca9dd398a673f6f0fa4f8221ce99e6b45ca69a165e5`.
Implementation and isolated acceptance are complete; the fixed trial's deployment result is recorded separately below.

## What was verified

All model/tool acceptance ran against throwaway accounts and Postgres, the real plugin daemon, the signed
OpenAI-compatible 0.0.68 plugin and a controlled local model origin. The separate tool fixture uses the SDK protocol
bridge documented in [tool acceptance](runtime-tools-acceptance.md). No paid provider or real trial account was used.
The isolated browser gateway used a self-signed localhost certificate with verification disabled **only in that
fixture**. This does not establish trusted TLS or physical-device performance; the actual trial retains Tailscale TLS.

- Eight real HTTP/model groups cover blocking/streaming, immutable published revisions across draft edits and
  republishing, separate passports/API users, two-turn model memory, a blocking provider refusal, file ownership,
  human-input pause and actual persisted log/token data.
- Six further real boundary groups cover two API callers, invalid/deleted keys, site disable/code rotation, nested
  workflow-tool files and child-log exclusion, Chatflow file links in live/blocking/history/reconnect responses,
  blocking Chatflow pause/resume, and cancellation of a real in-flight tool invocation. A foreign user cannot stop it;
  the owning user's stopped terminal state is persisted.
- Ten real browser groups cover anonymous Start inputs and execution, a second isolated visitor, actual file selection
  and multipart bytes, two model-backed chat turns and reload without duplicate generation, visible provider refusal
  and retry from the previous successful parent, failed history loading without another generation, failed form POST
  and the actual SSE disconnection through a **new server process on the same database**, durable completed-state
  reload, the fixed upstream embed script's actual Flutter iframe, and English/Chinese/light/dark at 1,100/390 widths.
  The paused run's preceding model invocation occurs once across restart. Screenshots show retained form input during
  the failure. Headless Chromium at 390 pixels is not an Android or iPhone test.

Reproducible HTTP checks are [acceptance.py](../e2e/public_app/acceptance.py) and
[boundaries.py](../e2e/public_app/boundaries.py). They refuse non-local fixture endpoints and use supplied private
fixture authentication. The K17 receipts and raw failures are retained in
`/var/tmp/Winnie/five-steps-cb9fa7f3/c/`; browser traces contain fixture bearer headers and are not public attachments.
Final receipts are `image-e2e4/result.json`, `image-boundaries3/result.json`, `browser4/result.json`,
`production-image.json`, `source-release.json` and `web-sha256.json`.

## Automated checks and their exact scope

- Full server baseline: **458 tests / 97 suites**, before the final message-latency/file projection/blocking-error
  refinements. The final refinements pass **14 tests / 5 suites** covering public identity/run/file/form/chat/monitoring
  routes plus existing console Chatflow and run-event behavior, with real Postgres. This is not a claim of a full
  461-test rerun after every refinement.
- Full Flutter baseline: **5,996 passed, 3 existing external-environment skips**, before the final public chat
  failure/file refinements. Final related UI/design tests: **27 passed**; final public/tool API tests: **5 passed**.
  App and package analysis are clean. The package full suite passes **283, with 2 existing external-environment skips**.
- Feature ledger: **294 entries**, with generated documentation checked. The public service runtime is recorded as
  implemented; the public share-page row remains partial because the complete original chat layout and branding
  behavior are not reproduced. The existing visual baseline is not relabeled as passing.

Independent regressions first exposed lost chat failure feedback, lost retry input/parent state, the final
`message_end` clearing a failed terminal, history-load retries invoking the run action instead of reading state, and caller-less Chatflow file projection.
These are fixed. Harness failures are retained too: wrong translated button labels; waiting for an indeterminate
loader with `pumpAndSettle`; a chat fixture with End rather than Answer; assuming daemon-reported latency instead of
the engine's measured latency; and failing to reset a deliberately refused local model between cases. One browser
check read the unfocused native editing element before Flutter synchronized it; the final check focuses without
changing its contents and also verifies the actual retry prompt at the model boundary. No visual thresholds, masks,
image resampling or text exclusions were changed.

## Behavior and remaining boundaries

See [protocol 1.20](protocol.md#published-web-and-service-api-120). API users are deliberately namespaced by API-key ID;
rotating a key starts a new history namespace. A web visitor uses a separate opaque passport. Console credentials
never authorize a public run. Public responses omit the execution account's email; console monitoring explicitly
projects the end user. Draft variables and debug runs remain separate from published traffic.

Published files retain the same expiring, transferable signed-download contract as earlier file delivery. All local
references, previews, forms, runs, histories and stop/events APIs additionally enforce public end-user ownership.
Blocking Chatflow failure returns HTTP 400 `workflow_run_failed` rather than an empty successful answer; typed output
files are additionally exposed as `files`. Human-input blocking pause retains the original top-level message identity
and paused data envelope. Statistics use stored provider usage and original mode guards; completion-only latency is
not falsely enabled for Chatflow. Missing price data remains null.

The public page is a minimal shared-control runner. Full chat-page pixel parity, complete branding/customization,
rich historical failure presentation, extension messaging, Agent v2 and knowledge/OCR are not claimed. Helper
services and real annotation matching are the next grouped stage. Email remains independently disabled.

## Fixed trial deployment

The fixed trial has been updated at **https://k17.tail4653d.ts.net/**, inside the existing Tailscale network,
with no Funnel. All 1,598 HTTPS resources match the frozen build. A fresh browser loaded the actual Wasm renderer,
used same-origin API discovery and reported no page errors. This read-only online check used no real account or paid
model; execution acceptance used the separate fixtures described above.

The upgrade preserved the original database and upload volume, all environment settings, both encryption/signing keys,
and the old-column fingerprints of 30 protected tables. Verified private database/upload backups and the previous API
and gateway containers remain available. No database dump was restored over newer writes. Online receipts are
`actual-backend-upgrade.json`, `gateway-deployment.json`, `actual-assets.json` and `https-browser.json` in the K17 evidence
directory. The production image uses the server tree recorded above; subsequent documentation changes do not rebuild it.
