# Native read-only workflow MCP

This native client interface and its two checklist tools are **dify-sf extensions**,
not upstream Dify console/MCP endpoints.

The normal Flutter Linux executable optionally serves **only** `read_workflow`
and `check_workflow` over loopback Streamable HTTP. It runs the editor's existing
`computeChecklist` and `checkBeforePublish`; there is no second validator or DSL
importer. Protocol handling uses the maintained `mcp_dart` SDK, pinned to 2.4.3.
No workflow edit, import, execution, publishing or approval tool is registered.
Checks accept an existing draft ID, not a YAML pathname. Import a file as a new
draft through the existing API, then check that draft ID and revision. Retain a
complete, clean draft; delete or correct a draft with warnings before delivery.
Import and deletion stay outside this read-only MCP interface.

## Build and sign in

Use the repository's pinned Flutter SDK and its ordinary Linux prerequisites:

```sh
cd app
flutter pub get
flutter build linux --release
```

For headless operation, sign in once with the pure Dart helper. It needs no
Flutter window, Weston, `DISPLAY` or Wayland connection:

```sh
cd packages/collab_client
dart pub get
dart run bin/login_profile.dart --server URL \
  --credentials-file /private/login.json --profile /private/profile
```

The input is an owner-only **0600** regular JSON file with exactly `email` and
`password` fields. The helper reuses `AuthSession.login`, creates a **0700** profile
and writes the existing **0600** token-store format, then exits. It prints a
constant success/failure message; passwords, tokens, account data and remote error
payloads are never printed. Invalid configuration exits 78; failed sign-in exits
1 and leaves an existing valid profile unchanged. Use the **same server URL** and
`--mcp-profile /private/profile` when starting the native client below.

An existing private native profile or ordinary interactive sign-in also works.
The MCP caller never receives the login credentials or token pair, and no login
tool is registered in MCP. Keep different accounts/environments in separate
profiles. The input credential file stays under the operator's control.

Create a **different**, random local MCP access key in an owner-only file:

```sh
umask 077
openssl rand -hex 32 > /private/mcp.key
```

The MCP key is a local capability to read workflows accessible to that signed-in
account. Grant it only to intended local callers. The endpoint listens exclusively
on `127.0.0.1`, validates Host and refuses requests carrying an Origin header.
It is not an unauthenticated browser API or a remotely exposed service.

## Run under Weston without a display

On Linux with Weston 14 and its headless backend installed:

```sh
export DIFYSF_CLIENT_BINARY=/checkout/app/build/linux/x64/release/bundle/dify_sf_app
export DIFYSF_MCP_RUNTIME_ROOT=/private/runtime-root
# On managed machines, set the existing common cleanup lock as well:
# export DIFYSF_CLEANUP_LOCK=/path/to/machine-cleanup.lock
# Isolate settings/cache when testing; keep the explicit auth profile separate.
export XDG_CONFIG_HOME=/private/config XDG_DATA_HOME=/private/data XDG_CACHE_HOME=/private/cache
./tool/mcp/run_headless.sh --server URL --volatile --lang en-US \
  --mcp-profile /private/profile --mcp-port 39391 --mcp-token-file /private/mcp.key
```

Create the runtime root with mode 0700 first. The wrapper creates its own Wayland
socket, uses Weston's headless/pixman compositor and keeps the client's default
Flutter GPU setting. No shared display, X11 or Xvfb is used. Readiness of the MCP
listener does not mean account sign-in has completed; tools fail closed until a
valid account is restored. Logs contain no login tokens or MCP key.

SIGTERM/interrupt stops the client and compositor; Weston removes its socket,
then the wrapper removes its empty disposable runtime directory. Profiles and logs
remain. Run the wrapper in a resource-limited service on shared machines. This is
a full GUI client per process, not a lightweight Dart daemon.

## Call the two tools

Use a Streamable HTTP MCP client at `http://127.0.0.1:39391/mcp` with an
`Authorization: Bearer <local MCP key>` header. Tools accept:

```json
{"workflow_id":"app-id","expected_revision":42}
```

`expected_revision` is optional. A mismatch returns `complete:false` and
`error:"revision_changed"`. The app ID is the document ID in dify-sf.

- `read_workflow` returns the server's atomic snapshot revision, the document
  representation (including typed/broken references), graph positions and edge
  handles, features and variable declarations. This is committed server state;
  it does not include uncommitted edits from another window.
- `check_workflow` reads one atomic document snapshot and runs the actual editor
  rules against it. It returns `draft_revision`, `items`, `warning_count`,
  `publish_error`, `complete`, `unavailable_context` and `gate_passed`.
  Require **both** `complete:true` and `gate_passed:true` for a clean gate.
  A version labels the checked snapshot; later edits require another check.

No account credentials or provider credentials are serialized. Workflow config
itself can contain user-entered sensitive text and should be treated with the
same access controls as reading that workflow in the editor.

The stdlib Python gate client can replace one-off validation scripts:

```sh
python3 tool/mcp/check_workflow.py --token-file /private/mcp.key app-id
```

Exit 0 means complete and clean; 1 means warnings, publish rejection, incomplete
context or revision mismatch; 2 means connection/authentication/protocol failure.
It closes its MCP session after use. It also supports `--revision` and `--endpoint`.

## Completeness and supported context

Graph, features and variables come from the same snapshot, with the server's
sequence number. Model provider summaries and builtin/workflow tool providers
are fetched only when the graph needs them. Fetch failures remain **unknown**,
not an empty successful catalog. Missing installed providers can produce warnings
normally; a catalog failure prevents `gate_passed` even when partial rules return
zero items. Incomplete results have `warning_count:null` and an explicit
`partial_warning_count`; they never advertise a clean zero total. No catalogs or provider credential values are returned to the caller.

The first read-only bridge does not yet wire every context required by the editor ports.
API/MCP tool provider catalogs, legacy/inline Agent backend checks, knowledge
retrieval dataset context, trigger plugin and data-source catalogs are explicitly
reported as `unsupported_context` / `tool_catalog` when applicable, and make the
check incomplete. This first slice does not claim full upstream Dify validation
for such workflows. Plain graph/code/HTTP/iteration/loop/human-input workflows
can be complete without unrelated catalogs. The existing editor validator's
upstream scope and limitations still apply.

`complete` is about the requested operation: `read_workflow` can read a complete
snapshot even when the graph requires an unavailable catalog for validation.
Never use read completeness as a substitute for `check_workflow.gate_passed`.

## Verification

`cd packages/collab_client && dart test test/login_profile_cli_test.dart test/auth_test.dart`
checks no-display profile creation and normal session restore, rejected permissions
and symlinks, failed-login profile preservation and credential-safe error messages.

`flutter test test/mcp test/dify_spec/workflow/hooks/use_checklist_test.dart
 test/dify_spec/workflow/header/checklist_test.dart` exercises version guards,
unknown-context gating and the existing checklist/hook UI rules. Native runtime
acceptance must additionally verify actual Weston first frame, authenticated MCP
calls against a real isolated server/database, same-snapshot item differences,
idle/checking memory and shutdown cleanup. A compositor starting alone is not
proof that Flutter rendered. Never use actual trial credentials or publish private
workflow fixtures in this repository.

Startup/cleanup failures can be checked without any account or server:

```sh
python3 tool/mcp/test_startup.py --binary /checkout/app/build/linux/x64/release/bundle/dify_sf_app \
  --output /private/fresh-acceptance-directory
```

This covers missing/weak/public keys, missing options, malformed ports and an
owned occupied port. All fail closed with exit 78, a generic error and no display
socket left behind. Keep the output/runtime path short enough for Unix sockets.
For exact live acceptance captures, set `MCP_DIFFERENTIAL_DIR` when running
`test/mcp/server_snapshot_differential_test.dart`; it compares the full ordered
editor item JSON and first publish error at the captured server revision.
