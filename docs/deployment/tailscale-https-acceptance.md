# Tailnet HTTPS trial acceptance — 2026-10-24

The fixed trial address is **https://k17.tail4653d.ts.net/**. Devices must be connected to the existing tailnet. Tailscale Serve forwards HTTPS to a loopback-only nginx gateway; Funnel is not enabled.

The current frontend is the complete Flutter 3.47.6 Wasm release from `e0b84fd` (same application tree as `f167fb4`), frozen in `helpers-e0b84fd`. The current API image is `f6d9c59902d92fd82cfc422509bbdf94a41660c9552364895d9d12ed939e8509`, built from a clean source context with the repository Dockerfile. The HTTPS gateway retains JavaScript MIME for `.mjs`, signed `/files/`, `/v1/`, original query strings and streaming behavior. First-visit clients use the same HTTPS origin; saved server choices and explicit overrides retain precedence.

A/B/C/D updates preserved the original PostgreSQL container/volume, upload volume and encryption/file-signing keys. The D update matched fingerprints of all existing columns in **30** protected tables, retaining private database/upload backups and previous API/gateway containers. It adds only an internal authenticated annotation vector service URL/key: fixed Weaviate 1.39.2, independent persistent volume, 640 MiB / 1 CPU, no anonymous access or host port. Legacy annotation settings require explicit rebuilding and do not cause automatic model calls. Details: [helper acceptance](helpers-acceptance.md), [public runtime acceptance](../runtime-public-acceptance.md), [tools](../runtime-tools-acceptance.md).

The current deployed **1,598** assets all match the frozen build by SHA-256. A fresh actual HTTPS browser loaded Dart Wasm and Skwasm, reached ready, made only same-origin setup/features GETs and reported no page error. No actual user login or paid model call was used. The checks below retain the original A scope; later stage results are recorded in their linked acceptance documents.

## Verification

- Release Wasm build, eight targeted Flutter tests, static analysis, font checks and fourteen bootstrap-policy tests passed. Three gateway-rendering checks cover origins/configuration injection, loopback binding, streaming and module MIME configuration.
- Certificate verification and all **1595** live asset SHA-256 comparisons passed. Actual browser loading fetched the application Wasm and Skwasm, reached the ready state and reported no JavaScript error. Fresh clients requested `/v1/setup` and `/v1/system-features` on the same HTTPS origin.
- An isolated HTTP receiver verified that the identical gateway configuration forwards authorization, original query strings and external-host information; multipart bytes and download bytes matched. Streaming delivered the first frame in about 1 ms and remained open for 36 seconds. Restart health passed.
- Against a separate PostgreSQL database and the actual production API image, real login/refresh, multipart upload, a server-issued signed `/files/` download, workflow pause, gateway restart, state reattachment, human-input submission and successful completion all passed.
- The frozen frontend completed a real sign-in against that isolated API. Two live browser windows received the same document operation through their existing collaboration streams. Light, dark and 390-pixel-wide captures were checked; no browser error was recorded.

The initial live browser check caught the nginx MIME table serving `.mjs` as binary: the bootstrap then selected CanvasKit. This was corrected and the actual Wasm check was repeated successfully. Early fixture failures (restart readiness race, an invalid human-input fixture type, omitted snapshot query and a title operation aimed at a config field) are retained in the execution evidence; they are not counted as product passes.

## Scope and limits

Browser execution used Chromium, including a narrow viewport; it is not physical Android or iPhone evidence. Physical Safari performance should be checked by opening the HTTPS address directly. Existing visual-parity differences remain tracked separately; these captures do not claim complete Dify visual equivalence.

Real user accounts were not used for tests. No paid model invocation, plugin installation in the live daemon, database reset or key rotation was performed. Published end-user Web/API execution, tools and the agreed auxiliary scope have subsequently been delivered with separate acceptance records above. Email remains disabled.

Operational configuration and rollback instructions are in [tailscale-https.md](tailscale-https.md). Resource ownership and the maintenance review are recorded in Raft task #27. The review date is a maintenance follow-up, not an automatic shutdown of the trial.
