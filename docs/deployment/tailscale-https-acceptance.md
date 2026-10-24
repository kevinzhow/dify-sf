# Tailnet HTTPS trial acceptance — 2026-10-24

The fixed trial address is **https://k17.tail4653d.ts.net/**. Devices must be connected to the existing tailnet. Tailscale Serve forwards HTTPS to a loopback-only nginx gateway; Funnel is not enabled.

The frontend uses the complete Wasm release built from `4580d34` (Flutter 3.47.6). Gateway corrections are `8974a0b` (JavaScript MIME for `.mjs`) and `b83bdc9` (the server's signed `/files/` routes, as well as `/v1/`). First-visit clients use the same HTTPS origin. Saved server choices and explicit launch overrides retain precedence.

The API retains production image `a2c6deef4fd429b88bc800282d1cedcb275d1f0daca26ce9684db712b4978933`. Its only configuration changes are the HTTPS external file origin and an explicit internal file origin retaining the existing HTTP route. Existing encryption and file-signing keys, PostgreSQL container/volume and upload volume are preserved. Fingerprints of all existing columns in 21 protected tables matched before and after applying the configuration. The previous API container, database backup and upload backup are retained privately for recovery.

## Verification

- Release Wasm build, eight targeted Flutter tests, static analysis, font checks and fourteen bootstrap-policy tests passed. Three gateway-rendering checks cover origins/configuration injection, loopback binding, streaming and module MIME configuration.
- Certificate verification and all **1595** live asset SHA-256 comparisons passed. Actual browser loading fetched the application Wasm and Skwasm, reached the ready state and reported no JavaScript error. Fresh clients requested `/v1/setup` and `/v1/system-features` on the same HTTPS origin.
- An isolated HTTP receiver verified that the identical gateway configuration forwards authorization, original query strings and external-host information; multipart bytes and download bytes matched. Streaming delivered the first frame in about 1 ms and remained open for 36 seconds. Restart health passed.
- Against a separate PostgreSQL database and the actual production API image, real login/refresh, multipart upload, a server-issued signed `/files/` download, workflow pause, gateway restart, state reattachment, human-input submission and successful completion all passed.
- The frozen frontend completed a real sign-in against that isolated API. Two live browser windows received the same document operation through their existing collaboration streams. Light, dark and 390-pixel-wide captures were checked; no browser error was recorded.

The initial live browser check caught the nginx MIME table serving `.mjs` as binary: the bootstrap then selected CanvasKit. This was corrected and the actual Wasm check was repeated successfully. Early fixture failures (restart readiness race, an invalid human-input fixture type, omitted snapshot query and a title operation aimed at a config field) are retained in the execution evidence; they are not counted as product passes.

## Scope and limits

Browser execution used Chromium, including a narrow viewport; it is not physical Android or iPhone evidence. Physical Safari performance should be checked by opening the HTTPS address directly. Existing visual-parity differences remain tracked separately; these captures do not claim complete Dify visual equivalence.

Real user accounts were not used for tests. No paid model invocation, plugin installation in the live daemon, database reset or key rotation was performed. Published end-user Web/API execution, tool execution and auxiliary services remain separate milestones.

Operational configuration and rollback instructions are in [tailscale-https.md](tailscale-https.md). Resource ownership and the maintenance review are recorded in Raft task #27. The review date is a maintenance follow-up, not an automatic shutdown of the trial.
