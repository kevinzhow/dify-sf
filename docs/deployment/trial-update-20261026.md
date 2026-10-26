# Trial update acceptance — 2026-10-26

The frontend and Swift API were upgraded to product source `9cb617eb8d4771cd65b1687a20a7753890156d32`. The trial's Agent service and sandbox supervisor now support the inline workflow subset. This is an authorized trial update; it does not make the whole upstream Agent App/roster available or change the default switches in source.

## Artifact binding

The deployed app/server/client/service source was compared byte-for-byte across 4263 tracked product files with the previously tested candidate. The Web release has 1604 files, with `main.dart.wasm` SHA-256 `476473a92d2ac337edffa95ceb0ea4637840f211b26a8de2368960fb853339c0`. All deployed Web files matched their frozen manifest. The Swift executable reuses the exact release-with-enable-testing artifact from the complete regression and restart run; it was not rebuilt from an unreviewed working tree. The runtime image includes its adjacent model-resource bundle. Both Dart AOT executables match reviewed service commit `a4e622d`.

## Checks

- Complete source candidate: 540 Swift tests / 123 suites passed; 6050 Flutter tests passed, with 4 explicit environment-dependent skips. Linux and Web/Wasm release builds passed. Standalone Dart service: 124 passed, 4 Docker-gated skips.
- New production images rehearsed an old-version synthetic database upgrade: existing account, app, document, snapshots and operations remained identical before login; the old workflow still succeeded. Comparing fingerprints after login was an invalid first harness attempt because login deliberately updates the account; that failure is retained separately.
- With the embedded production-image executables, a real server A was stopped and B adopted its unanswered Agent pause. After over 137 seconds, beyond the remote 120-second lease, two native questions completed under ownership generation 2. The shell effect happened once; nested output bytes matched; 15 unique logs and the original node-start header were preserved; ACK/cleanup drained. The model endpoint was a local synthetic fixture behind the signed official provider plugin.
- Actual upgrade: verified private database/upload backups; 30 existing tables' original-column fingerprints remained identical. Account/provider/secret and signing keys were preserved. New schema tables/columns are not treated as old-data changes.
- The API retained its three network addresses. The existing exact proxy policy was not expanded: the approved health route still passed with certificate validation, while neighboring addresses/ports and other private destinations were refused. Tailscale Serve, the original code sandbox, database, vector service and reports were retained.
- One anonymous browser context installed the old service worker, then refreshed across the upgrade and loaded the new Wasm hash. Desktop 1440 and narrow 390 views loaded with no page/resource errors and same-origin API requests. No real user account was logged into for acceptance. Cache headers and all 1604 application resources were checked. Existing reports were unchanged.

These checks do not claim paid-model quality, physical-device frame rates or a fresh full 450-scene visual pass. The last complete visual result remains 171 strict / 68 basic / 211 different from 2026-10-25.

## Runtime budget and ownership

The persistent trial components are owned by Winnie and restart unless stopped. The API retains 1 GiB / 1 CPU. The Agent service uses 384 MiB / 0.5 CPU; its supervisor uses 256 MiB / 0.25 CPU. Only the supervisor receives the Docker socket; neither service publishes a host port. Agent records and supervisor state live in separate private persistent directories, and credentials are stored outside the Web root in mode-0600 files.

Each shell execution gets the fixed official local-sandbox image, its own container/network, 384 MiB / 0.5 CPU, 128 PIDs, 64 MiB home and 128 MiB workspace. No proxy peer is configured, so shell network egress remains unavailable. Running Agent admission defaults to two operations; unanswered human questions do not consume that running budget. Provider credentials remain in Swift. Users choose a compatible model with tool-call support; their existing model selections and credentials are not replaced.

This deployment explicitly sets `COLLAB_AGENT_INLINE_ENABLED=true` and `COLLAB_AGENT_SHELL_ENABLED=true`. The service URL and authentication key are private deployment configuration. The code defaults remain false. SMTP mail remains disabled.

## Rollback and lifecycle

The previous API and gateway containers, frozen frontend, database dump and upload archive are preserved. Rollback restores executable/static versions and original network addresses, never a database dump over subsequent user writes. Current authoritative deployment receipts record the actual container/image IDs, configuration and artifact manifests; private keys, user records and real endpoint allowlists are excluded from public documentation.

These resources remain while this trial is in use, until explicitly replaced or retired. The existing maintenance reminder was updated to cover the gateway, API, Agent service/supervisor, persistent state, limits and rollback records on 2026-11-24; that review date is not an automatic shutdown instruction.

See the [next improvement plan](../migration-plan.md) for the outstanding Web, visual, runtime and device work.
