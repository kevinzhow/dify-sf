# Tailnet HTTPS trial

Trial devices connect to Tailscale first, then open the machine's `https://<machine>.<tailnet>.ts.net/` directly in the browser. Tailscale Serve terminates HTTPS and forwards to a loopback-only nginx gateway. The gateway serves a frozen Web build and proxies `/v1/` and `/files/` to the existing API, including event streams and signed file downloads. Fresh Web clients use that same origin by default; a saved server or explicit `server` query still takes precedence. Native clients keep their existing default.

This is Serve within the tailnet. Do not enable Funnel. Access from devices outside the tailnet requires a separate explicit decision.

## Set up

1. Build and verify the complete release Web package (`--wasm --no-web-resources-cdn`), including the repository's bootstrap policy. Freeze the output in a versioned directory and retain the previous directory.
2. Render the nginx configuration:

   ```sh
   python3 tool/tailscale_gateway.py --api-origin http://127.0.0.1:19097 \
     --listen-port 19197 --output /path/to/nginx.conf
   ```

   Use the API's actual listening address. It need not be loopback; the gateway itself binds only loopback. The generated config requires the standard nginx MIME table.
3. Run a pinned nginx image with host networking, a read-only config mounted at `/etc/nginx/nginx.conf`, and the frozen build mounted at `/srv/web`. Use a non-root UID, drop all capabilities, enable `no-new-privileges`, cap memory/CPU/PIDs, and supply a bounded writable `/tmp` tmpfs. All nginx temporary paths are below `/tmp`. Set `--restart unless-stopped`.
4. An authorized machine operator runs once:

   ```sh
   sudo tailscale serve --bg --https=443 http://127.0.0.1:19197
   ```

   Read `tailscale serve status --json` and confirm port 443 forwards to the intended loopback port. Confirm no `AllowFunnel` entry is enabled. HTTPS issuance may take a short time; verify without bypassing certificate validation.
5. Set the API's `COLLAB_FILES_URL` to the HTTPS origin so newly issued signed downloads and avatar URLs use HTTPS too. If plugins or server-side consumers need a separate internal route, keep it explicit in `COLLAB_FILES_INTERNAL_URL`. Preserve both existing encryption/signing keys and the existing database/upload volumes. Apply this configuration only after checking active runs and retaining a verified backup plus the previous container.
6. Open the HTTPS address directly, without the old `server=http://...` query. A fresh origin should use HTTPS for `/v1/` requests, streams, and files. If this device deliberately saved an old HTTP backend, change its server setting to the HTTPS origin.

## Acceptance and recovery

Verify certificate validation, anonymous authorization refusal, `/healthz`, deep-link fallback, correct Wasm MIME type, and asset hashes. Against an isolated backend, test login, a live event stream, multipart upload and signed download through the same rendered proxy configuration. Stop/restart the gateway and recheck service health and frontend hashes. Keep real user accounts and stored workflows out of test fixtures.

Persist both Docker and Tailscale services across reboot. Updating the frozen Web mount does not require changing Serve configuration. Save the exact image digest, launch arguments, config hash and frozen-directory manifest with each deployment.

Rollback by replacing only the gateway's image/config/frozen mount with the previously recorded launch arguments, on the same loopback port. Preserve the existing API container, database, uploads, application encryption keys and file signing keys. A frontend rollback never restores an old database over newer user writes. Verify HTTPS health and asset hashes again. The earlier HTTP trial may remain available during this transition; it is unsuitable for Safari performance acceptance.

## Safari performance

Use a direct HTTPS navigation for iOS Web performance comparisons. A script navigation from an HTTP page may retain an existing enhanced-security process. The browser reporting a secure context alone does not prove that JIT acceleration is enabled. Record actual renderer and operating system alongside timing evidence; simulator results are not physical-device frame rates. See [the client deployment notes](../client.md) for the recorded investigation.


## Current retained trial resources (2026-10-24, D update)

- Owner and maintenance contact: Winnie; authoritative tracking: Raft task #27 and #dify:b521f2fc. The 2026-11-24 review is a maintenance check, not an automatic shutdown or permission to delete data. Keep the trial until an explicit revocation or replacement, and propagate any endpoint change to users.
- HTTPS gateway `winnie-https-trial-gateway`: loopback 19197 behind the existing Tailscale Serve 443; non-root/read-only, 128 MiB / 0.5 CPU, frozen `helpers-bf53ed1`, backend `/v1/` and signed files on the same HTTPS origin. Funnel remains off.
- API `winnie-files-trial-server`: clean image `f6d9c599`, 1 GiB / 1 CPU; existing three runtime networks, PostgreSQL and upload volumes retained. The private configuration authority remains at its existing local path; original encryption and file-signing keys are unchanged.
- Annotation service `winnie-trial-annotation-vector`: fixed Weaviate 1.39.2 digest, 640 MiB / 1 CPU, `unless-stopped`, authenticated internal service, no host port; persistent `winnie-trial-annotation-vectors`. Its private key and vector volume join the backup set. Legacy annotation flags are `needs_rebuild`, without automatic embedding calls.
- The D private backup directory contains a verified database dump, upload archive, old-column fingerprints, original environment and exact previous container inspection, plus `ROLLBACK.md`. The previous C API/gateway containers remain stopped and retained. Never publish that directory, use it as test data, restore it over newer user writes, or remove current data as part of rollback.

For rollback, inspect current runs/writes, stop and retain the new containers under unique names, restore the prior container names and start them against the **current** PostgreSQL/uploads. Restore the prior configuration authority with the prior API, retaining both original keys; keep the additive schema. Preserve the vector service/key/volume, stopping its process if no longer needed. Validate current health and HTTPS before redirecting traffic. Database dumps are disaster-recovery material, not a routine downgrade operation.

For retained visual reports on this same HTTPS origin, render the gateway with `--reports` and mount an explicit, reviewed public report directory read-only at `/srv/reports`. Only that opt-in mount is served at `/reports/`; missing reports return 404 rather than the application shell. Never mount the working directory, authentication fixtures, database backups or private evidence there. Keep product assets on their existing independent frozen mount. Do not enable directory listing. Report publication does not require Funnel or an additional listening port.

For a fresh empty database, use `/healthz` as process liveness and a successful `GET /v1/setup` as application/schema readiness before bootstrapping an account or admitting traffic. A liveness response alone does not prove that the initial schema migration has finished.

The retained 450-case report is at [the same-origin report URL](https://k17.tail4653d.ts.net/reports/five-step-final-20261024/). Its 5,416 static files match SHA-256 over actual HTTPS. It uses an independent read-only mount, preserves the product/API/vector state and has desktop/390-width filtering and overlay checks. The viewer combines pass plus basic-pass into its Pass 237 badge; the delivery report preserves the original 171/66/213 split.
