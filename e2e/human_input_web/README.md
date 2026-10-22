# Human-input web recovery

This fixture opens the built Flutter app in Playwright Chromium and clicks its real
form controls against a separate server/PostgreSQL pair. It never uses the shared
trial database. Build the client with `tool/build_web.sh` first, and provide a
release `collab-server` plus its `DifySF_CollabModels.bundle` under
`<runtime-cache>/release/`.

```sh
python run.py --runtime-cache /path/to/runtime-cache \
  --web-build /path/to/client/app/build/web --output /path/to/evidence
```

Dependencies: Docker, the repository's `dify-sf-dev:local` runtime/toolchain image,
Python Playwright and its Chromium browser. Use the machine's agreed resource
wrapper; the fixture separately limits its own containers. Ports default to
localhost 19092/18992 and can be changed with `--server-port`/`--web-port`.

Use `--production-image --image <release-image>` to test the shipped entrypoint and
its bundled binary/model catalog instead; `--runtime-cache` is unnecessary then.
The image's default user is preserved in this mode.

The light-theme case kills the server while a form is open, attempts an actual
submit while offline, starts another server process against the same private
database, and waits for the browser's events request to reconnect. A database
trigger temporarily refuses the resume claim; a nontransactional sequence proves
that the immediate attempt and a later production recovery pass both run. After
removing the fault, the already accepted answer must finish without another
submit, and its correct output must reach the page. The dark-theme case runs the
same real form normally. Screenshots and a JSON result record both themes and the
actual Dart Wasm/skwasm resources. No model daemon or outbound email is configured.

All containers/networks have unique names and are removed on exit. Output stays
in the requested evidence directory; keep that directory private, since runtime
logs and screenshots can contain fixture form identifiers.
